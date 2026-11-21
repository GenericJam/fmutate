/*
 * c_src/fm1audio.c — the mixer NIF (FMutate.AudioNif): FMutate's mixer (c_src/fm1mix.c) as the mob_audio_io
 * processor "fm1_mixer", and its slots. The output stream itself (AAudio on Android, a RemoteIO unit and the
 * audio session on iOS) is mob_audio_io's: FMutate.Audio opens it with MobAudioIo.open/3.
 *
 * Statically linked into the app binary as the NIF `fm1audio` (mob.exs :static_nifs, beside the plugin's
 * mob_audio_io_nif, whose C ABI fm1mix.c calls); its load registers the processor. Elixir side:
 * FMutate.AudioNif / FMutate.Audio.
 */
#include <erl_nif.h>

#include "fm1mix.c"

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *a) { return enif_make_atom(env, a); }

static ERL_NIF_TERM error_text(ErlNifEnv *env, const char *t)
{
    return enif_make_tuple2(env, atom(env, "error"), enif_make_string(env, t, ERL_NIF_LATIN1));
}

static int get_slot(ErlNifEnv *env, ERL_NIF_TERM t, int *s)
{
    return enif_get_int(env, t, s) && *s >= 0 && *s < NSLOT;
}

/* attach(slot, path) -> :ok | {:error, reason}; the slot starts silent (gain 0) */
static ERL_NIF_TERM nif_attach(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s;
    char path[1024];
    const char *err;
    (void)argc;
    if (!get_slot(env, argv[0], &s)) return enif_make_badarg(env);
    if (enif_get_string(env, argv[1], path, sizeof path, ERL_NIF_LATIN1) <= 0) {
        ErlNifBinary bin;
        if (!enif_inspect_binary(env, argv[1], &bin) || bin.size >= sizeof path) return enif_make_badarg(env);
        memcpy(path, bin.data, bin.size);
        path[bin.size] = 0;
    }
    err = fm1mix_attach(s, path);
    return err ? error_text(env, err) : atom(env, "ok");
}

static ERL_NIF_TERM nif_detach(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s;
    (void)argc;
    if (!get_slot(env, argv[0], &s)) return enif_make_badarg(env);
    fm1mix_detach(s);
    return atom(env, "ok");
}

/* gain(slot, permille, ramp_ms) -> :ok */
static ERL_NIF_TERM nif_gain(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int s, g, ramp;
    (void)argc;
    if (!get_slot(env, argv[0], &s) || !enif_get_int(env, argv[1], &g) || !enif_get_int(env, argv[2], &ramp))
        return enif_make_badarg(env);
    fm1mix_gain(s, g, ramp);
    return atom(env, "ok");
}

/* stats() -> %{frame, rate, peak, running, callbacks, fills, underruns}
 * (rate: the stream's at its last start, 44100 before any; running: between the stream's start and stop) */
static ERL_NIF_TERM nif_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM keys[7], vals[7], fills[NSLOT], unders[NSLOT], map;
    struct fm1mix_stats o;
    (void)argc; (void)argv;
    fm1mix_stats(&o);
    for (int s = 0; s < NSLOT; s++) {
        fills[s] = enif_make_uint(env, o.fills[s]);
        unders[s] = enif_make_uint(env, o.underruns[s]);
    }
    keys[0] = atom(env, "frame");     vals[0] = enif_make_uint64(env, o.frame);
    keys[1] = atom(env, "rate");      vals[1] = enif_make_int(env, o.rate);
    keys[2] = atom(env, "peak");      vals[2] = enif_make_uint(env, o.peak);
    keys[3] = atom(env, "running");   vals[3] = atom(env, o.running ? "true" : "false");
    keys[4] = atom(env, "callbacks"); vals[4] = enif_make_uint64(env, o.callbacks);
    keys[5] = atom(env, "fills");     vals[5] = enif_make_list_from_array(env, fills, NSLOT);
    keys[6] = atom(env, "underruns"); vals[6] = enif_make_list_from_array(env, unders, NSLOT);
    enif_make_map_from_arrays(env, keys, vals, 7, &map);
    return map;
}

/* the processor is registered once, at load: a failed registration fails the load (FMutate.AudioNif.loaded?/0) */
static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void)env; (void)priv; (void)info;
    return fm1mix_register() == MAI_OK ? 0 : 1;
}

static ErlNifFunc nif_funcs[] = {
    {"attach", 2, nif_attach, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"detach", 1, nif_detach, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"gain", 3, nif_gain, 0},
    {"stats", 0, nif_stats, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.FMutate.AudioNif, nif_funcs, load, NULL, NULL, NULL)
