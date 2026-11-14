/*
 * c_src/fm1io.c — the bridge between the BEAM and FMutate's Kotlin side (fmutate/FMutateIO.kt): the audio-output
 * list, and what learned MIDI controls show on the instrument surface. MIDI itself is the mob_midi plugin's.
 *
 * Statically linked into the app binary as the NIF `fm1io` (mob.exs :static_nifs, Android only); Elixir side:
 * FMutate.IONif, owned by FMutate.IO (audio outputs) and FMutate.MIDI (surface).
 *
 * Kotlin → BEAM: the audio outputs as a JSON document to the event pid: {fm1io, event, Json}.
 * BEAM → Kotlin (dirty IO NIFs): call/1 (JSON command → JSON reply); surface/1 (text lines for the instrument
 * surface, FMutateIO.surface: queued there and applied once per display frame).
 */
#include <erl_nif.h>

#include <jni.h>
#include <pthread.h>
#include <string.h>

extern JavaVM *g_jvm; /* beam_jni.c, set in JNI_OnLoad */

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int has_events;
static ErlNifPid events_pid;

static jclass io_class;            /* FMutateIO, a global ref taken in nativeInit (app class loader) */
static jmethodID m_call;
static jmethodID m_surface;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name)
{
    ERL_NIF_TERM a;
    return enif_make_existing_atom(env, name, &a, ERL_NIF_LATIN1) ? a : enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static JNIEnv *jni(void)
{
    JNIEnv *env = NULL;
    if (!g_jvm) return NULL;
    if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    /* dirty scheduler threads live as long as the VM: attach once, never detach */
    if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != JNI_OK) return NULL;
    return env;
}

/* ---- NIFs */

/* loaded() -> true: the stub raises on a host */
static ERL_NIF_TERM nif_loaded(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return atom(env, "true");
}

/* subscribe_events(Pid) -> ok: JSON events from Kotlin go to Pid */
static ERL_NIF_TERM nif_subscribe_events(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifPid pid;
    (void)argc;
    if (!enif_get_local_pid(env, argv[0], &pid)) return enif_make_badarg(env);
    pthread_mutex_lock(&lock);
    events_pid = pid;
    has_events = 1;
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
}

/* call(Json :: binary()) -> {ok, Reply :: binary()} | {error, not_ready | exception} */
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary in, out;
    JNIEnv *j;
    char *req;
    (void)argc;
    if (!enif_inspect_binary(env, argv[0], &in)) return enif_make_badarg(env);
    if (!io_class || !(j = jni())) return error(env, "not_ready");
    req = enif_alloc(in.size + 1);
    memcpy(req, in.data, in.size);
    req[in.size] = 0;
    jstring jreq = (*j)->NewStringUTF(j, req);
    enif_free(req);
    jstring jrep = (jstring)(*j)->CallStaticObjectMethod(j, io_class, m_call, jreq);
    (*j)->DeleteLocalRef(j, jreq);
    if ((*j)->ExceptionCheck(j)) {
        (*j)->ExceptionDescribe(j);
        (*j)->ExceptionClear(j);
        return error(env, "exception");
    }
    if (!jrep) return error(env, "exception");
    const char *rep = (*j)->GetStringUTFChars(j, jrep, NULL);
    size_t n = strlen(rep);
    enif_alloc_binary(n, &out);
    memcpy(out.data, rep, n);
    (*j)->ReleaseStringUTFChars(j, jrep, rep);
    (*j)->DeleteLocalRef(j, jrep);
    return enif_make_tuple2(env, atom(env, "ok"), enif_make_binary(env, &out));
}

/* surface(Text :: binary()) -> ok | {error, not_ready | exception} */
static ERL_NIF_TERM nif_surface(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary in;
    JNIEnv *j;
    char *text;
    (void)argc;
    if (!enif_inspect_iolist_as_binary(env, argv[0], &in)) return enif_make_badarg(env);
    if (!io_class || !m_surface || !(j = jni())) return error(env, "not_ready");
    text = enif_alloc(in.size + 1);
    memcpy(text, in.data, in.size);
    text[in.size] = 0;
    jstring jtext = (*j)->NewStringUTF(j, text);
    enif_free(text);
    (*j)->CallStaticVoidMethod(j, io_class, m_surface, jtext);
    (*j)->DeleteLocalRef(j, jtext);
    if ((*j)->ExceptionCheck(j)) {
        (*j)->ExceptionDescribe(j);
        (*j)->ExceptionClear(j);
        return error(env, "exception");
    }
    return atom(env, "ok");
}

/* ---- JNI, from FMutateIO.kt */

JNIEXPORT void JNICALL
Java_com_example_fmutate_1app_fmutate_FMutateIO_nativeInit(JNIEnv *env, jclass cls)
{
    pthread_mutex_lock(&lock);
    if (!io_class) {
        io_class = (jclass)(*env)->NewGlobalRef(env, cls);
        m_call = (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;");
        m_surface = (*env)->GetStaticMethodID(env, cls, "surface", "(Ljava/lang/String;)V");
    }
    pthread_mutex_unlock(&lock);
}

JNIEXPORT void JNICALL
Java_com_example_fmutate_1app_fmutate_FMutateIO_nativeEvent(JNIEnv *env, jclass cls, jstring json)
{
    ErlNifPid pid;
    ErlNifEnv *menv;
    ERL_NIF_TERM bin;
    (void)cls;
    pthread_mutex_lock(&lock);
    int found = has_events;
    pid = events_pid;
    pthread_mutex_unlock(&lock);
    if (!found) return;
    const char *s = (*env)->GetStringUTFChars(env, json, NULL);
    size_t n = strlen(s);
    menv = enif_alloc_env();
    memcpy(enif_make_new_binary(menv, n, &bin), s, n);
    (*env)->ReleaseStringUTFChars(env, json, s);
    enif_send(NULL, &pid, menv,
              enif_make_tuple3(menv, enif_make_atom(menv, "fm1io"), enif_make_atom(menv, "event"), bin));
    enif_free_env(menv);
}

static ErlNifFunc nif_funcs[] = {
    {"loaded", 0, nif_loaded, 0},
    {"subscribe_events", 1, nif_subscribe_events, 0},
    {"call", 1, nif_call, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"surface", 1, nif_surface, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.FMutate.IONif, nif_funcs, NULL, NULL, NULL, NULL)
