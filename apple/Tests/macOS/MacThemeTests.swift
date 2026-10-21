import XCTest
import AppKit
import SwiftUI
import PrivateInputKit

final class MacThemeTests:XCTestCase {
    func contrast(_ a:NSColor,_ b:NSColor)->Double {
        func luminance(_ value:NSColor)->Double {
            let c=value.usingColorSpace(.sRGB)!
            func linear(_ v:CGFloat)->Double {let x=Double(v);return x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        let x=luminance(a),y=luminance(b)
        return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
    func testEveryAccentHasReadableLightAndDarkPalette() {
        for accent in MacTheme.Accent.allCases {
            for dark in [false,true] {
                let p=MacTheme(accent:accent).palette(dark:dark)
                // Treat the translucent base as composited over the worst wallpaper.
                let worst=p.background.blended(withFraction:0.06,of:dark ? .white:.black)!
                for background in [p.background,worst] {
                    XCTAssertGreaterThanOrEqual(contrast(p.text,background),4.5)
                    XCTAssertGreaterThanOrEqual(contrast(p.secondary,background),4.5)
                    XCTAssertGreaterThanOrEqual(contrast(p.accent,background),4.5)
                }
                XCTAssertGreaterThanOrEqual(contrast(p.selectedText,p.selection),4.5)
                XCTAssertGreaterThanOrEqual(contrast(p.accent,p.selection),3)
            }
        }
    }
    func testPreferenceRoundTripAndInvalidDataFallback() throws {
        let suite="PrivateInput-Theme-Test-"+UUID().uuidString,store=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {store.removePersistentDomain(forName:suite)}
        XCTAssertEqual(MacThemePreferences.read(from:store),MacTheme())
        for mode in MacTheme.Mode.allCases {
            for accent in MacTheme.Accent.allCases {
                let value=MacTheme(mode:mode,accent:accent)
                MacThemePreferences.write(value,to:store)
                XCTAssertEqual(MacThemePreferences.read(from:store),value)
            }
        }
        for value in [Data("{\"mode\":\"unknown\"}".utf8),Data(repeating:0,count:513)] {
            store.set(value,forKey:MacThemePreferences.key)
            XCTAssertEqual(MacThemePreferences.read(from:store),MacTheme())
        }
        XCTAssertNil(MacTheme.Mode.system.appearance)
        XCTAssertEqual(MacTheme.Mode.light.appearance?.name,.aqua)
        XCTAssertEqual(MacTheme.Mode.dark.appearance?.name,.darkAqua)
    }
    @MainActor func testSettingsAndCandidateAdoptThemeWithoutMovingOrTakingFocus() throws {
        // An isolated defaults suite is used above; here only post a refresh and
        // vary the window's drawing appearance, never change daily preferences.
        let panel=MacCandidatePanel(),screen=try XCTUnwrap(NSScreen.main)
        defer {panel.hide()}
        let rows=(0..<36).map {InputCandidate(text:"可读候选\($0)",comment:"",index:$0)}
        panel.show(items:rows,selected:7,offset:6,expanded:true,caret:NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:1,height:22))
        let frame=panel.frame,id=panel.panelIdentifier
        NotificationCenter.default.post(name:MacThemePreferences.updated,object:nil)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            panel.appearanceForAcceptance(appearance)
            XCTAssertEqual(panel.frame,frame);XCTAssertEqual(panel.panelIdentifier,id);XCTAssertFalse(panel.takesKeyFocus)
            let window=MacSettingsWindowLayout.makeWindow(rootView:Form {MacAppearanceSettings()}.formStyle(.grouped))
            window.appearance=NSAppearance(named:appearance)
            XCTAssertEqual(window.contentMinSize,MacSettingsWindowLayout.minimumContentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let output=FileManager.default.temporaryDirectory.appendingPathComponent("PrivateInput-Theme53-"+appearance.rawValue+".png")
            try panel.saveAcceptanceSnapshot(output)
            if let view=window.contentView,let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:output.deletingLastPathComponent().appendingPathComponent("PrivateInput-Settings53-"+appearance.rawValue+".png"))
            }
            window.close()
        }
    }
}
