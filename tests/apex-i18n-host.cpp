// ─────────────────────────────────────────────────────────────────────────────
//  apex-i18n-host.cpp — a bare QQmlEngine, the shape quickshell uses, so the
//  Apex.I18n route can be measured on a machine that has no quickshell.
//
//  ── Why this exists rather than "just run quickshell" ───────────────────────
//
//  The GitHub Arch runner has no quickshell — it is an AUR package — so a suite
//  that can only measure the route in situ measures NOTHING on the machine the
//  gate runs on. That is the same reason tests/quickshell-a11y-cause.cpp was
//  written, and this file is the same trick pointed at translation: it builds
//  the host out of the two lines quickshell's launcher uses —
//
//      QQmlEngine engine;                    // bare. NOT QQmlApplicationEngine
//      engine.addImportPath(<module root>);
//
//  — and nothing else. A QQmlApplicationEngine would load an i18n/qml_<lang>.qm
//  by itself and every measurement below would be about Qt's convenience
//  wrapper instead of about the shell's host. tests/run-i18n-test.sh section 4
//  is the proof that the bare engine is the right shape: it reads quickshell's
//  symbol table and finds QQmlEngine's constructor and no QQmlApplicationEngine
//  at all.
//
//  ── The five modes ──────────────────────────────────────────────────────────
//
//    plain            no import path, probe.qml (no import)      -> English
//    plugin           import path + a catalogue                  -> German
//    nocat            import path, catalogue directory EMPTY     -> English
//    late             no plugin; the host installs a QTranslator
//                     AFTER the tree exists                      -> English
//    late-retranslate the same, plus engine.retranslate()        -> German
//
//  `plain` and `nocat` are the two halves of a negative that would otherwise be
//  one word. Without `nocat`, "the plugin is present" and "a catalogue was
//  found" are a single claim, and a plugin that loaded nothing at all would
//  read exactly like a missing translation. Without `plain` there is no run in
//  which the plugin is absent, so nothing shows the German came from it.
//
//  `late` and `late-retranslate` are the reason the plugin does its work from
//  initializeEngine(). A QTranslator installed after a binding has been
//  evaluated does not change it; Qt re-evaluates translation bindings only when
//  the engine is told to. The pair measures that instead of asserting it, and
//  it is the fact that a future "just call installTranslator somewhere in
//  main()" would break on.
//
//  Everything is read off the LIVE object through the property system. Nothing
//  here parses QML source.
// ─────────────────────────────────────────────────────────────────────────────
#include <QGuiApplication>
#include <QLocale>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QString>
#include <QTranslator>
#include <QUrl>
#include <cstdio>

static void report(QObject *o, const char *tag)
{
    printf("APEXHOST %s entryLabel=%s\n", tag,
           qPrintable(o->property("entryLabel").toString()));
    printf("APEXHOST %s cardRead=%s\n", tag,
           qPrintable(o->property("cardRead").toString()));
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);

    const QString mode    = qEnvironmentVariable("APEX_I18N_MODE");
    const QString stage   = qEnvironmentVariable("APEX_I18N_STAGE");
    const QString imports = qEnvironmentVariable("APEX_I18N_IMPORTS");
    const QString trdir   = qEnvironmentVariable("APEX_SHELL_TRANSLATIONS");

    if (mode.isEmpty() || stage.isEmpty()) {
        fprintf(stderr, "APEX_I18N_MODE and APEX_I18N_STAGE are required\n");
        return 2;
    }
    printf("APEXHOST mode=%s\n", qPrintable(mode));
    printf("APEXHOST locale=%s\n", qPrintable(QLocale().name()));

    // The bare engine. This line, and the import path below it, are the whole
    // host: everything else in this file is measurement.
    QQmlEngine engine;

    const bool wantsPlugin = (mode == QLatin1String("plugin")
                              || mode == QLatin1String("nocat"));
    if (wantsPlugin) {
        if (imports.isEmpty()) {
            fprintf(stderr, "mode %s needs APEX_I18N_IMPORTS\n", qPrintable(mode));
            return 2;
        }
        engine.addImportPath(imports);
        printf("APEXHOST importPath=%s\n", qPrintable(imports));
    }

    const QString probe = wantsPlugin ? QStringLiteral("probe-import.qml")
                                      : QStringLiteral("probe.qml");
    printf("APEXHOST probe=%s\n", qPrintable(probe));

    QQmlComponent component(&engine, QUrl::fromLocalFile(stage + QLatin1Char('/') + probe));
    QObject *root = component.create();
    if (!root) {
        // A component that did not instantiate has no strings to read, and a
        // run that printed no strings must not be mistaken for a run that
        // printed English ones. Say so and leave, loudly.
        const auto errors = component.errors();
        for (const auto &e : errors)
            fprintf(stderr, "APEXHOST error: %s\n", qPrintable(e.toString()));
        printf("APEXHOST create=FAILED\n");
        return 3;
    }
    printf("APEXHOST create=ok\n");

    report(root, "first");

    if (mode == QLatin1String("late") || mode == QLatin1String("late-retranslate")) {
        auto *tr = new QTranslator(&app);
        if (tr->load(QLocale(), QStringLiteral("apex-shell"), QStringLiteral("_"), trdir)) {
            QCoreApplication::installTranslator(tr);
            printf("APEXHOST late-install=%s\n", qPrintable(tr->filePath()));
        } else {
            printf("APEXHOST late-install=FAILED\n");
        }
        if (mode == QLatin1String("late-retranslate")) {
            engine.retranslate();
            printf("APEXHOST retranslate=called\n");
        }
        report(root, "second");
    }

    printf("APEXHOST done=%s\n", qPrintable(mode));
    return 0;
}
