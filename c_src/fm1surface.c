/*
 * c_src/fm1surface.c — iOS: what learned MIDI controls show on the instrument surface (FMutate.MIDI), handed to
 * the Swift surface's queue (fm1_surface_offer, ios/FMutateMidiSurface.swift), which applies it on the main
 * thread. Android does the same through fm1io.c's surface/1 (JNI, FMutateIO.surface).
 *
 * Statically linked into the app binary as the NIF `fm1surface` (mob.exs :static_nifs, iOS only); Elixir side:
 * FMutate.SurfaceNif.
 */
#include <erl_nif.h>

/* Swift (@_cdecl): copies the text into its queue; any thread, never blocks for long */
extern void fm1_surface_offer(const unsigned char *text, long n);

static ERL_NIF_TERM nif_loaded(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_atom(env, "true");
}

/* surface(Text :: iodata()) -> ok */
static ERL_NIF_TERM nif_surface(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary in;
    (void)argc;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &in)) return enif_make_badarg(env);
    fm1_surface_offer(in.data, (long)in.size);
    return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"loaded", 0, nif_loaded, 0},
    {"surface", 1, nif_surface, 0},
};

ERL_NIF_INIT(Elixir.FMutate.SurfaceNif, nif_funcs, NULL, NULL, NULL, NULL)
