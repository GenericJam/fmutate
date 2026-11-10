package com.example.fmutate_app.fmutate

import com.example.fmutate_app.MobNativeViewRegistry

/**
 * Registers FMutate's native views with Mob. Names follow Mob's convention: the Elixir component module
 * with "Elixir." dropped and dots as underscores (FMutate.InstrumentView → "FMutate_InstrumentView").
 * Called from MainActivity.onCreate.
 */
object FMutateViews {
    fun register() {
        MobNativeViewRegistry.register("FMutate_InstrumentView") { props, send -> InstrumentView(props, send) }
    }
}
