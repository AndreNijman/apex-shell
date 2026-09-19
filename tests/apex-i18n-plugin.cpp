// ─────────────────────────────────────────────────────────────────────────────
//  apex-i18n-plugin.cpp — the host change P2-004 has been blocked on since
//  round 3, in 60 lines of C++ that APEX can ship on its own.
//
//  ── What was blocked, and why this is the shape of the fix ──────────────────
//
//  Every user-facing string in this shell goes through qsTr(). qsTr() calls
//  QCoreApplication::translate(), which walks the list of installed
//  QTranslators. If that list is empty the call returns its argument unchanged
//  and a German user reads English. Nothing in QML can add to that list:
//  QTranslator is a C++ class and is not a QML type, so no file under src/ can
//  install one however it is written. That is tests/run-i18n-test.sh section 4,
//  and it is why the ledger has carried "blocker is the host" for thirty
//  rounds.
//
//  The reading that went with it — that the host is quickshell's and therefore
//  somebody else's to change — is one step too pessimistic. quickshell
//  constructs a bare QQmlEngine, and a bare QQmlEngine still loads QML modules
//  off QML_IMPORT_PATH, and a QML module may carry a compiled plugin, and a
//  compiled plugin runs C++ inside the shell's own process before a single
//  binding is evaluated. So the host change is a module APEX ships and imports,
//  not a patch anybody else has to accept.
//
//  ── Why QQmlExtensionPlugin and not QQmlEngineExtensionPlugin ───────────────
//
//  QQmlEngineExtensionPlugin is the modern class and it is the wrong one here,
//  in a way that costs an afternoon if you do not know it. With it the .so is
//  found, dlopen()ed — proved with a library constructor that printed — and the
//  qmldir is read, and the import STILL fails with
//
//      module "Apex.I18n" is not installed
//
//  because nothing registered the module and initializeEngine() is therefore
//  never reached. Adding a plain QML type to the qmldir does not fix it either.
//  What fixes it is registerTypes() calling qmlRegisterModule(), which only
//  QQmlExtensionPlugin has. The deprecation warning is real and the class still
//  works; when it goes, the replacement is a module built by Qt's own CMake
//  machinery, which registers itself.
//
//  ── Why initializeEngine and not "somewhere later" ──────────────────────────
//
//  A QTranslator installed AFTER the QML tree exists changes nothing that was
//  already evaluated, unless the engine is asked to re-evaluate. That is not an
//  opinion: tests/apex-i18n-host.cpp runs both and the suite asserts the pair.
//  initializeEngine() runs while the import is being resolved, i.e. before the
//  file that imported it has instantiated anything, which is the one moment
//  where no re-evaluation is needed. retranslate() is called anyway so that a
//  module imported lazily from somewhere deeper still behaves.
//
//  ── Where the catalogue comes from ──────────────────────────────────────────
//
//  /usr/share/apex-shell/translations/apex-shell_<lang>.qm by default, and the
//  directory is overridable through APEX_SHELL_TRANSLATIONS so a test can point
//  it at a stage directory without the shipped path being load-bearing. The
//  language is the system locale, not an APEX setting: per-user language is a
//  separate roadmap row and this file must not quietly become it.
//
//  Absence is reported, never swallowed. "no catalogue for de_DE" and "this
//  plugin never ran" are different states and a silent plugin cannot tell them
//  apart — the whole defect family this program keeps meeting.
// ─────────────────────────────────────────────────────────────────────────────
#include <QCoreApplication>
#include <QLocale>
#include <QQmlEngine>
#include <QQmlExtensionPlugin>
#include <QString>
#include <QTranslator>
#include <QtQml>

class ApexI18nPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
    // Without this the module does not exist as far as the engine is
    // concerned, whatever the qmldir says and whatever the .so contains.
    void registerTypes(const char *uri) override
    {
        qInfo("APEXI18N: registerTypes uri=%s", uri);
        qmlRegisterModule(uri, 1, 0);
    }

    void initializeEngine(QQmlEngine *engine, const char *uri) override
    {
        qInfo("APEXI18N: initializeEngine uri=%s", uri);

        const QString dir = qEnvironmentVariable(
            "APEX_SHELL_TRANSLATIONS",
            QStringLiteral("/usr/share/apex-shell/translations"));

        // Parented to the application: the translator has to outlive this
        // call, and an unparented one leaks or is collected depending on
        // nothing you can see from here.
        auto *tr = new QTranslator(QCoreApplication::instance());
        if (tr->load(QLocale(), QStringLiteral("apex-shell"),
                     QStringLiteral("_"), dir)) {
            QCoreApplication::installTranslator(tr);
            qInfo("APEXI18N: installed %s", qPrintable(tr->filePath()));
        } else {
            qInfo("APEXI18N: no catalogue for %s in %s",
                  qPrintable(QLocale().name()), qPrintable(dir));
            delete tr;
        }

        if (engine)
            engine->retranslate();
    }
};

#include "apex-i18n-plugin.moc"
