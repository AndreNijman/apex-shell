// ─────────────────────────────────────────────────────────────────────────────
//  tests/quickshell-a11y-cause.cpp — the reproduction behind FOUND 14/20:
//  why NOTHING in this repository's accessibility markup reaches AT-SPI.
//
//  Driven by tests/check-quickshell-a11y-cause.sh. Never linked into the shell.
//
//  ── The finding ─────────────────────────────────────────────────────────────
//
//  tests/run-lockscreen-atspi.sh measures that the running shell publishes ONE
//  node to the accessibility bus — its own application node — and nothing
//  beneath it. Rounds 28 and 29 narrowed that to a single fact:
//  QQuickWindow::accessibleRoot() returns null for every one of quickshell's
//  top-level windows, and QAccessibleApplication::childCount() is the size of
//  topLevelObjects(), which keeps only windows with a non-null root.
//
//  The cause is a three-line interaction between qtbase, qtdeclarative and
//  quickshell, and no single one of them is obviously wrong:
//
//    * qtbase, src/gui/accessible/qaccessible.cpp — QAccessible::installFactory
//      registers qAccessibleCleanup with qAddPostRoutine, and that routine does
//      qAccessibleFactories()->clear(). Post routines run from
//      ~QCoreApplication.
//    * qtdeclarative, src/quick/util/qquickglobal.cpp — QQuick_initializeModule
//      installs qQuickAccessibleFactory, and it is a Q_CONSTRUCTOR_FUNCTION:
//      it runs ONCE, when libQt6Quick is loaded, and can never run again.
//    * quickshell, src/launch/main.cpp:127 — constructs a QCoreApplication to
//      parse the command line; src/launch/launch.cpp:282 then does
//      `delete coreApplication;` on the line before `new QGuiApplication(...)`.
//
//  So the first application object's destructor empties Qt's accessibility
//  factory list, nothing ever refills it, and for the rest of the process's
//  life queryAccessibleInterface() walks the metaobject chain against an empty
//  list and returns null for everything.
//
//  ── Why this file exists rather than a paragraph ────────────────────────────
//
//  Every link above is a claim about someone else's source. This runs it. Five
//  modes, one process each, selected by APEX_REPRO_MODE:
//
//    A  QCoreApplication -> delete -> QGuiApplication      what quickshell does
//    B  QGuiApplication only                           what qml-qt6 does (the
//                                                      round-29 control, which
//                                                      publishes a full tree)
//    C  A, plus OUR factory installed from a Q_CONSTRUCTOR_FUNCTION — the same
//       registration shape qtdeclarative uses. If the list is really cleared,
//       our factory disappears too, and that is the direct read of the defect:
//       qAccessibleFactories() is a Q_GLOBAL_STATIC and is not an exported
//       symbol, so it cannot be inspected any other way.
//    D  A, plus OUR factory installed from Q_COREAPP_STARTUP_FUNCTION, which
//       qt_call_pre_routines runs from every QCoreApplicationPrivate::init()
//       and does not clear. THIS IS THE ONE-LINE UPSTREAM FIX, measured: it is
//       what qtdeclarative would use instead of Q_CONSTRUCTOR_FUNCTION.
//    E  A, plus OUR factory installed by hand after the QGuiApplication exists
//       — the shape of the LD_PRELOAD instrument in
//       tests/quickshell-a11y-shim.cpp, which confirms all of this inside the
//       real quickshell process.
//
//  Qt Widgets is immune for mode D's reason: QApplicationPrivate::initialize()
//  installs its factory per instance, not per library load.
//
//  Headless by construction: QT_QPA_PLATFORM=offscreen and the window is never
//  shown. An unmapped window still has an accessible root (see FOUND 16 in the
//  p2-b card), so nothing here needs a compositor, a bus or a screen.
// ─────────────────────────────────────────────────────────────────────────────

#include <QtCore/QCoreApplication>
#include <QtGui/QGuiApplication>
#include <QtGui/qaccessible.h>
#include <QtGui/qaccessibleobject.h>
#include <QtQuick/QQuickWindow>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const char *mode()
{
    const char *m = getenv("APEX_REPRO_MODE");
    return m ? m : "A";
}

// Deliberately minimal, and deliberately named: the name is how the suite tells
// OUR root from the one Qt's own QAccessibleQuickWindow would have produced.
class ApexRoot : public QAccessibleObject
{
public:
    explicit ApexRoot(QObject *o) : QAccessibleObject(o) {}
    QAccessibleInterface *parent() const override { return nullptr; }
    QAccessibleInterface *child(int) const override { return nullptr; }
    int childCount() const override { return 0; }
    int indexOfChild(const QAccessibleInterface *) const override { return -1; }
    QString text(QAccessible::Text t) const override
    {
        return t == QAccessible::Name ? QStringLiteral("APEX-CUSTOM-ROOT") : QString();
    }
    QAccessible::Role role() const override { return QAccessible::Window; }
    QAccessible::State state() const override { return QAccessible::State(); }
};

static QAccessibleInterface *apexFactory(const QString &cn, QObject *o)
{
    if (cn == QLatin1String("QQuickWindow"))
        return new ApexRoot(o);
    return nullptr;
}

static void installApexFactory(const char *who)
{
    QAccessible::installFactory(&apexFactory);
    printf("install: %s installed apexFactory\n", who);
}

// The shape qtdeclarative uses today: once, at load, never again.
static void apexCtor()
{
    if (strcmp(mode(), "C") == 0)
        installApexFactory("Q_CONSTRUCTOR_FUNCTION");
}
Q_CONSTRUCTOR_FUNCTION(apexCtor)

// The shape the fix uses: once per QCoreApplicationPrivate::init().
static void apexStartup()
{
    if (strcmp(mode(), "D") == 0)
        installApexFactory("Q_COREAPP_STARTUP_FUNCTION");
}
Q_COREAPP_STARTUP_FUNCTION(apexStartup)

int main(int, char **argv)
{
    const char *m = mode();
    printf("mode: %s\n", m);

    const bool deleteCoreApp = (strcmp(m, "B") != 0);

    if (deleteCoreApp) {
        int c = 1;
        auto *core = new QCoreApplication(c, argv);
        printf("coreapp: constructed\n");
        delete core;
        printf("coreapp: destroyed\n");
    } else {
        printf("coreapp: never constructed\n");
    }

    int c = 1;
    auto *app = new QGuiApplication(c, argv);
    printf("guiapp: constructed\n");

    if (strcmp(m, "E") == 0)
        installApexFactory("after-QGuiApplication");

    auto *w = new QQuickWindow();
    w->setTitle(QStringLiteral("QTROOT"));

    QAccessibleInterface *root = w->accessibleRoot();
    printf("accessibleRoot: %s\n", root ? "NON-NULL" : "NULL");
    if (root)
        printf("rootName: %s\n", qPrintable(root->text(QAccessible::Name)));

    QAccessibleInterface *appIface = QAccessible::queryAccessibleInterface(app);
    printf("appIface: %s\n", appIface ? "NON-NULL" : "NULL");
    if (appIface)
        printf("appChildCount: %d\n", appIface->childCount());

    delete w;
    delete app;
    return 0;
}
