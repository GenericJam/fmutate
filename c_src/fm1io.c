/*
 * c_src/fm1io.c — the I/O bridge between the BEAM and FMutate's Kotlin side (fmutate/FMutateIO.kt): MIDI
 * ports (android.media.midi), the audio devices, the Bluetooth MIDI scan.
 *
 * Statically linked into the app binary as the NIF `fm1io` (mob.exs :static_nifs, Android only); Elixir side:
 * FMutate.IONif, owned by FMutate.IO (device events) and FMutate.MIDI (MIDI routes).
 *
 * Kotlin → BEAM (JNI, called on any thread):
 *   - MIDI bytes go straight to the pid routed for their source with enif_send: no JSON, no main-thread hop,
 *     no Mob event queue. Message: {fm1io, midi, Source, Bytes, SentNs, RecvNs} (CLOCK_MONOTONIC ns: the
 *     sender's timestamp and when Kotlin got the bytes).
 *   - everything else (device lists, the audio route, scan results) is a JSON document to the event pid:
 *     {fm1io, event, Json}.
 * BEAM → Kotlin (dirty IO NIFs): call/1 (JSON command → JSON reply) and midi_send/3 (bytes out of an
 * instance's virtual port).
 *
 * Sources: an instance's virtual port is -1 - instance index (-1 = "a"); an opened device's output port is
 * device_id * 16 + port. A source without a route goes to the default route.
 */
#include <erl_nif.h>

#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

extern JavaVM *g_jvm; /* beam_jni.c, set in JNI_OnLoad */

#define MAX_ROUTES 32

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int used, source;
    ErlNifPid pid;
} routes[MAX_ROUTES];
static int has_default, has_events;
static ErlNifPid default_pid, events_pid;

static jclass io_class;            /* FMutateIO, a global ref taken in nativeInit (app class loader) */
static jmethodID m_call, m_midi_send;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name)
{
    ERL_NIF_TERM a;
    return enif_make_existing_atom(env, name, &a, ERL_NIF_LATIN1) ? a : enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* The pid for a source, under the lock. 0 = nobody. */
static int lookup(int source, ErlNifPid *pid)
{
    for (int i = 0; i < MAX_ROUTES; i++)
        if (routes[i].used && routes[i].source == source) {
            *pid = routes[i].pid;
            return 1;
        }
    if (has_default) {
        *pid = default_pid;
        return 1;
    }
    return 0;
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

/* route_midi(Source :: integer() | default, Pid) -> ok | {error, full} */
static ERL_NIF_TERM nif_route_midi(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifPid pid;
    int source, free_slot = -1;
    (void)argc;
    if (!enif_get_local_pid(env, argv[1], &pid)) return enif_make_badarg(env);
    pthread_mutex_lock(&lock);
    if (enif_is_identical(argv[0], atom(env, "default"))) {
        default_pid = pid;
        has_default = 1;
        pthread_mutex_unlock(&lock);
        return atom(env, "ok");
    }
    if (!enif_get_int(env, argv[0], &source)) {
        pthread_mutex_unlock(&lock);
        return enif_make_badarg(env);
    }
    for (int i = 0; i < MAX_ROUTES; i++) {
        if (routes[i].used && routes[i].source == source) {
            routes[i].pid = pid;
            pthread_mutex_unlock(&lock);
            return atom(env, "ok");
        }
        if (!routes[i].used && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) {
        pthread_mutex_unlock(&lock);
        return error(env, "full");
    }
    routes[free_slot].used = 1;
    routes[free_slot].source = source;
    routes[free_slot].pid = pid;
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
}

/* unroute_midi(Source :: integer() | default) -> ok */
static ERL_NIF_TERM nif_unroute_midi(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    int source;
    (void)argc;
    pthread_mutex_lock(&lock);
    if (enif_is_identical(argv[0], atom(env, "default"))) {
        has_default = 0;
    } else if (enif_get_int(env, argv[0], &source)) {
        for (int i = 0; i < MAX_ROUTES; i++)
            if (routes[i].used && routes[i].source == source) routes[i].used = 0;
    }
    pthread_mutex_unlock(&lock);
    return atom(env, "ok");
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

/* midi_send(Port :: integer(), Bytes :: binary(), TimestampNs :: integer()) -> ok | {error, _}
 * Port: the instance index whose virtual port sends; TimestampNs 0 = now. */
static ERL_NIF_TERM nif_midi_send(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    ErlNifSInt64 ts;
    int port;
    JNIEnv *j;
    (void)argc;
    if (!enif_get_int(env, argv[0], &port) || !enif_inspect_binary(env, argv[1], &bin) ||
        !enif_get_int64(env, argv[2], &ts))
        return enif_make_badarg(env);
    if (!io_class || !(j = jni())) return error(env, "not_ready");
    jbyteArray arr = (*j)->NewByteArray(j, (jsize)bin.size);
    (*j)->SetByteArrayRegion(j, arr, 0, (jsize)bin.size, (const jbyte *)bin.data);
    jboolean sent = (*j)->CallStaticBooleanMethod(j, io_class, m_midi_send, (jint)port, arr,
                                                  (jlong)(ts ? ts : now_ns()));
    (*j)->DeleteLocalRef(j, arr);
    if ((*j)->ExceptionCheck(j)) {
        (*j)->ExceptionDescribe(j);
        (*j)->ExceptionClear(j);
        return error(env, "exception");
    }
    return sent ? atom(env, "ok") : error(env, "no_listener");
}

/* now_ns() -> CLOCK_MONOTONIC in ns (Android's System.nanoTime clock) */
static ERL_NIF_TERM nif_now_ns(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_int64(env, now_ns());
}

/* ---- JNI, from FMutateIO.kt */

JNIEXPORT void JNICALL
Java_com_example_fmutate_1app_fmutate_FMutateIO_nativeInit(JNIEnv *env, jclass cls)
{
    pthread_mutex_lock(&lock);
    if (!io_class) {
        io_class = (jclass)(*env)->NewGlobalRef(env, cls);
        m_call = (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;");
        m_midi_send = (*env)->GetStaticMethodID(env, cls, "midiSend", "(I[BJ)Z");
    }
    pthread_mutex_unlock(&lock);
}

JNIEXPORT jboolean JNICALL
Java_com_example_fmutate_1app_fmutate_FMutateIO_nativeMidi(JNIEnv *env, jclass cls, jint source, jbyteArray data,
                                                          jint offset, jint count, jlong sent_ns, jlong recv_ns)
{
    ErlNifPid pid;
    ErlNifEnv *menv;
    ERL_NIF_TERM bin;
    unsigned char *p;
    (void)cls;
    pthread_mutex_lock(&lock);
    int found = lookup(source, &pid);
    pthread_mutex_unlock(&lock);
    if (!found || count <= 0) return JNI_FALSE;
    menv = enif_alloc_env();
    p = enif_make_new_binary(menv, (size_t)count, &bin);
    (*env)->GetByteArrayRegion(env, data, offset, count, (jbyte *)p);
    ERL_NIF_TERM msg[6] = {
        enif_make_atom(menv, "fm1io"), enif_make_atom(menv, "midi"), enif_make_int(menv, source), bin,
        enif_make_int64(menv, sent_ns), enif_make_int64(menv, recv_ns),
    };
    int ok = enif_send(NULL, &pid, menv, enif_make_tuple_from_array(menv, msg, 6));
    enif_free_env(menv);
    return ok ? JNI_TRUE : JNI_FALSE;
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
    {"route_midi", 2, nif_route_midi, 0},
    {"unroute_midi", 1, nif_unroute_midi, 0},
    {"subscribe_events", 1, nif_subscribe_events, 0},
    {"call", 1, nif_call, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"midi_send", 3, nif_midi_send, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"now_ns", 0, nif_now_ns, 0},
};

ERL_NIF_INIT(Elixir.FMutate.IONif, nif_funcs, NULL, NULL, NULL, NULL)
