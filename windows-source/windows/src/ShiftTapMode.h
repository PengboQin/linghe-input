#pragma once
#include <cstdint>
namespace private_input {
// Only a solitary Shift tap in the same editor toggles mode. Shift+letter,
// selection shortcuts, auto-repeat and focus changes retain normal semantics.
struct ShiftTapMode {
  bool down=false,used=false;
  uintptr_t editor=0;
  void press(uintptr_t context,bool otherModifier) {
    if(down)return;
    down=true;used=otherModifier;editor=context;
  }
  void otherKey(){if(down)used=true;}
  bool ready(uintptr_t context)const{return down&&!used&&editor==context&&context!=0;}
  void reset(){down=false;used=false;editor=0;}
};
}
