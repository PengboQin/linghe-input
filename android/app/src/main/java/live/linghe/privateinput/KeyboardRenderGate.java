package live.linghe.privateinput;
/** A header touch protects its cells; any key touch protects the keyboard body. */
final class KeyboardRenderGate {
 private volatile boolean touching;private boolean header,pending;
 boolean touching(){return touching;}
 void begin(boolean inHeader){touching=true;header=inHeader;}
 void pointerInHeader(boolean inHeader){if(touching&&inHeader)header=true;}
 boolean defer(boolean rebuildBody){if(touching&&(header||rebuildBody)){pending=true;return true;}return false;}
 boolean deferRail(){if(touching){pending=true;return true;}return false;}
 boolean end(){touching=false;header=false;boolean result=pending;pending=false;return result;}
}
