/* A NIF that does not yield.
 *
 * The point of the fault gradient is that pure Erlang cannot starve a scheduler
 * -- reduction counting preempts every loop that stays inside the VM. Native
 * code is outside that accounting, so a NIF that busy-loops holds its scheduler
 * thread until it returns. This is the smallest honest realisation of "an agent
 * generated native code that does not cooperate".
 *
 * Deliberately not a dirty NIF: scheduling it on a dirty scheduler is exactly
 * the mitigation, and the probe is measuring what happens without it.
 */

#include <erl_nif.h>
#include <time.h>

static ERL_NIF_TERM block(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int seconds;
  if (argc != 1 || !enif_get_int(env, argv[0], &seconds)) {
    return enif_make_badarg(env);
  }
  /* Busy-wait rather than sleep: a sleeping thread would be given up, and the
     scheduler could recover. This holds the thread. */
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - start.tv_sec >= seconds * 60) break;
  }
  return enif_make_atom(env, "ok");
}

/* The mitigation, measured rather than assumed: the identical busy-loop
 * scheduled onto a DIRTY CPU scheduler. Dirty schedulers are separate OS threads
 * from the normal ones, so if containment is available at all this is where it
 * comes from -- and it decides whether the worst row of the fault gradient can
 * be defended against or only observed. */
static ErlNifFunc funcs[] = {
    {"block", 1, block},
    {"block_dirty", 1, block, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(bad_nif, funcs, NULL, NULL, NULL, NULL)
