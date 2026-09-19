// ─────────────────────────────────────────────────────────────────────────────
//  I18nBootstrap.qml — the one file in this repository that names the Apex.I18n
//  module, and the reason it is a separate file rather than a line in shell.qml.
//
//  Importing a QML module is not optional at run time. If Apex.I18n is missing,
//  every file that imports it fails to load, and a failure in shell.qml is the
//  whole desktop: no bar, no popups, no settings window, no lock screen. The
//  module ships in the image at /usr/lib64/apex-shell/qml, so it is missing in
//  three ordinary situations — a checkout run straight out of git, a session
//  started without QML_IMPORT_PATH, and an OS older than the shell.
//
//  So shell.qml loads this file through Qt.createComponent() and reads the
//  status. A missing module becomes one named warning and an English shell,
//  which is what it should have been all along, instead of a machine with no
//  user interface.
//
//  Nothing is instantiated here on purpose. The module's whole effect happens
//  in C++ while the import is being resolved: its plugin's initializeEngine()
//  installs a QTranslator on the application and calls retranslate(), so every
//  qsTr() binding already in the tree is re-evaluated. See
//  tests/apex-i18n-plugin.cpp for the mechanism and tests/run-i18n-host-test.sh
//  for the measurement of it inside the real quickshell.
// ─────────────────────────────────────────────────────────────────────────────
import QtQml
import Apex.I18n

QtObject {
}
