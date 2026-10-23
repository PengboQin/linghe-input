#pragma once
#include <windows.h>
#include "../resources/BrandingResource.h"
namespace linghe::tsf {
// Only desktop system-tray support is declared. This is not an assertion of
// immersive, secure-mode, UIElement, COM-less or input-mode-compartment support.
inline constexpr GUID SystrayCategory={0x25504fb4,0x7bab,0x4bc1,{0x9c,0x69,0xcf,0x81,0x89,0x0f,0x0e,0xf5}};
inline constexpr UINT BrandingIconResource=LINGHE_BRANDING_ICON;
// RegisterProfile's unsigned icon field carries a signed negative resource ID,
// as in Microsoft's SampleIME. ID101 avoids -1's special count-query path.
// This is not the first-icon ordinal.
inline constexpr ULONG BrandingProfileIconIndex=static_cast<ULONG>(-static_cast<LONG>(BrandingIconResource));
inline constexpr DWORD SystrayProfileCapability=0x00020000;
static_assert(BrandingIconResource==101&&BrandingProfileIconIndex==0xffffff9bUL,"Explicit embedded branding icon identity");
}
