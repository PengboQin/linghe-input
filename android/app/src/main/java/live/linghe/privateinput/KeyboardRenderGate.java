package live.linghe.privateinput;
/** A header touch protects its cells; any key touch protects the keyboard body. */
final class KeyboardRenderGate {
 private boolean touching,header,pending;
 void begin(boolean inHeader){touching=true;header=inHeader;}
 void pointerInHeader(boolean inHeader){if(touching&&inHeader)header=true;}
 boolean defer(boolean rebuildBody){if(touching&&(header||rebuildBody)){pending=true;return true;}return false;}
 boolean end(){touching=false;header=false;boolean result=pending;pending=false;return result;}
}
