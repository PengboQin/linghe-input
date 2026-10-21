#include "ShiftTapMode.h"
#include <cassert>
#include <iostream>
int main(){private_input::ShiftTapMode s;
s.press(1,false);assert(s.ready(1));assert(!s.ready(2));s.reset();assert(!s.ready(1));
s.press(1,false);s.otherKey();assert(!s.ready(1));s.reset();
s.press(1,true);assert(!s.ready(1));s.reset();
s.press(1,false);s.press(1,false);assert(s.ready(1));s.reset();
s.press(0,false);assert(!s.ready(0));s.reset();
s.press(1,false);s.otherKey();s.reset();s.press(1,false);assert(s.ready(1));
std::cout<<"PASS Shift tap, chord, modifier, focus, repeat, and next-tap recovery\n";}
