// FMutateViews.swift: port of android/.../fmutate/FMutateViews.kt.
//
// Registers FMutate's native views with Mob. Names follow Mob's convention: the Elixir component module with
// "Elixir." dropped and dots as underscores (FMutate.InstrumentView → "FMutate_InstrumentView"). Called from
// ios/AppDelegate.m right after mob_register_plugins().

import SwiftUI

@_cdecl("fmutate_register_views")
public func fmutate_register_views() {
    MobNativeViewRegistry.shared.register("FMutate_InstrumentView") { props, send in
        AnyView(FMInstrumentRepresentable(props: props, send: send))
    }
}
