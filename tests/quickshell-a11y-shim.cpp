// ─────────────────────────────────────────────────────────────────────────────
//  tests/quickshell-a11y-shim.cpp — a test-only LD_PRELOAD that puts Qt's
//  accessibility factory back into a running quickshell, so this repository's
//  accessibility markup can be read back over real AT-SPI.
//
//  Built and used by tests/run-lockscreen-atspi-shim.sh. NEVER SHIPPED, and
//  nothing in the image or the shell references it. It is an instrument.
//
//  ── Why an instrument is needed at all ──────────────────────────────────────
//
//  tests/quickshell-a11y-cause.cpp reproduces the defect and names it:
//  ~QCoreApplication runs a post routine that CLEARS Qt's accessibility factory
//  list, qtdeclarative installs its factory from a Q_CONSTRUCTOR_FUNCTION that
//  can only run once per library load, and quickshell destroys a
//  QCoreApplication immediately before constructing its QGuiApplication. The
//  consequence is that every QQuickWindow::accessibleRoot() is null and the
//  shell publishes one node to AT-SPI — see tests/run-lockscreen-atspi.sh,
//  which pins exactly that.
//
//  The markup is therefore unverifiable from outside the process: an empty tree
//  satisfies every read-back assertion vacuously. This restores the factory in
//  a running quickshell so the markup CAN be read, which turns those vacuous
//  skips into assertions that can fail.
//
//  ── How it hooks ────────────────────────────────────────────────────────────
//
//  It interposes QGuiApplication::exec(). `nm -D /usr/bin/quickshell` shows
//  `U _ZN15QGuiApplication4execEv@Qt_6`, so the call goes through the PLT and
//  LD_PRELOAD can take it. It MUST tail-call the real one through
//  dlsym(RTLD_NEXT, …): exec() is what calls QAccessible::setRootObject(qApp),
//  and skipping that would break the AT-SPI bridge in a way indistinguishable
//  from the defect being measured.
//
//  The install happens from a timer on the main thread, not from exec() itself
//  and not from a helper thread. quickshell has not created its windows when
//  exec() is entered, and QAccessible::installFactory is not thread-safe.
//
//  The timer waits for a FILE, named by APEX_SHIM_TRIGGER, rather than a fixed
//  delay. The suite drives the lock first, reads the tree back to confirm the
//  defect in that same run, and only then touches the file. A fixed delay would
//  make the order of those two a race, and a suite whose control and whose
//  measurement can swap places measures nothing. APEX_SHIM_DELAY_MS remains as
//  a fallback for manual use when no trigger is set.
//
//  ── What it installs ────────────────────────────────────────────────────────
//
//  A faithful copy of qtdeclarative's qQuickAccessibleFactory
//  (src/quick/accessible/qquickaccessiblefactory.cpp), which is compiled into
//  libQt6Quick but not exported and so cannot be referenced by name. All three
//  branches, including the QQuickItemPrivate::isAccessible filter: a
//  window-only factory would produce a frame with zero children, because
//  QAccessibleQuickWindow::child() re-enters queryAccessibleInterface() for
//  each root item — and that would read as "the markup is still unreachable",
//  a false negative dressed as a finding.
// ─────────────────────────────────────────────────────────────────────────────

#include <QtCore/QCoreApplication>
#include <QtCore/QFile>
#include <QtCore/QTimer>
#include <QtGui/QGuiApplication>
#include <QtGui/qaccessible.h>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>
#include <QtQuick/private/qaccessiblequickitem_p.h>
#include <QtQuick/private/qaccessiblequicktextedit_p.h>
#include <QtQuick/private/qaccessiblequickview_p.h>
#include <QtQuick/private/qquickitem_p.h>
#include <QtQuick/private/qquicktextedit_p.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>

static QAccessibleInterface *apexQuickFactory(const QString &classname, QObject *object)
{
    if (classname == QLatin1String("QQuickWindow"))
        return new QAccessibleQuickWindow(qobject_cast<QQuickWindow *>(object));
    if (classname == QLatin1String("QQuickTextEdit"))
        return new QAccessibleQuickTextEdit(qobject_cast<QQuickTextEdit *>(object));
    if (classname == QLatin1String("QQuickItem")) {
        QQuickItem *item = qobject_cast<QQuickItem *>(object);
        if (!item)
            return nullptr;
        if (!QQuickItemPrivate::get(item)->isAccessible)
            return nullptr;
        return new QAccessibleQuickItem(item);
    }
    return nullptr;
}

// Printed for every top-level window, before and after. This is the direct read
// of the cleared factory list from inside the process; there is no other one,
// because qAccessibleFactories() is a Q_GLOBAL_STATIC and not an exported
// symbol, so gdb cannot reach it either.
static void report(const char *when)
{
    const auto windows = QGuiApplication::topLevelWindows();
    fprintf(stderr, "APEXSHIM %s: topLevelWindows=%lld\n", when, (long long)windows.size());
    for (int i = 0; i < windows.size(); ++i) {
        QWindow *w = windows.at(i);
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w);
        fprintf(stderr, "APEXSHIM %s: window[%d] type=%d class=%s root=%s\n",
                when, i, int(w->type()), w->metaObject()->className(),
                iface ? "NON-NULL" : "NULL");
    }
    QAccessibleInterface *appIface = QAccessible::queryAccessibleInterface(qApp);
    fprintf(stderr, "APEXSHIM %s: appChildCount=%d\n", when,
            appIface ? appIface->childCount() : -1);
    fflush(stderr);
}

static void doInstall()
{
    report("before");
    QAccessible::installFactory(&apexQuickFactory);
    fprintf(stderr, "APEXSHIM: installFactory(apexQuickFactory) called\n");
    fflush(stderr);
    report("after");
    fprintf(stderr, "APEXSHIM: DONE\n");
    fflush(stderr);
}

extern "C" int apex_gui_exec() __asm__("_ZN15QGuiApplication4execEv");

extern "C" int apex_gui_exec()
{
    const char *trigger = getenv("APEX_SHIM_TRIGGER");
    const char *d = getenv("APEX_SHIM_DELAY_MS");
    const int delay = d ? atoi(d) : 5000;

    fprintf(stderr, "APEXSHIM: interposed QGuiApplication::exec(), trigger=%s delay=%dms\n",
            trigger ? trigger : "<none>", delay);
    fflush(stderr);

    if (trigger) {
        const QString path = QString::fromLocal8Bit(trigger);
        auto *t = new QTimer(qApp);
        t->setInterval(250);
        QObject::connect(t, &QTimer::timeout, qApp, [t, path]() {
            if (!QFile::exists(path))
                return;
            t->stop();
            doInstall();
        });
        t->start();
    } else {
        QTimer::singleShot(delay, qApp, []() { doInstall(); });
    }

    using Fn = int (*)();
    Fn real = (Fn)dlsym(RTLD_NEXT, "_ZN15QGuiApplication4execEv");
    if (!real) {
        fprintf(stderr, "APEXSHIM: FATAL dlsym(RTLD_NEXT, exec) failed: %s\n", dlerror());
        fflush(stderr);
        return 1;
    }
    return real();
}
