package live.linghe.privateinput;

/** A provider emits only facts it observes. It never owns server or consent policy. */
interface ActivityArchiveProvider {
  String[] capabilities();
  void start(String sourceApp,boolean safeField);
  void pause();
  void committed(String text,boolean editorAcknowledged);
  void flush();
  String health();
}
