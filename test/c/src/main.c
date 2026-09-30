/*
 * cclient: a hub client in C, testing include/hub/hub.h and lib/hub_glue.s.
 *
 * Each run adds one to a counter kept in a hub block and prints it. Until
 * the counter reaches 5, it opens a frame with one job and itself as the
 * continuation. Run 3's job fails on purpose (stop on error), so run 4 --
 * that frame's continuation -- reports the failure; the other runs report
 * a clean frame. It also checks that an over-long command is refused.
 *
 * The same source is built by agondev as cclient, by acc on the host as
 * cclienta (-DCLIENT_ACC) and by acc on the Agon as cclientc (-DCLIENT_CARD),
 * each with a block of its own, since blocks outlive the runs of one client.
 */
#include <stdio.h>
#include <string.h>

#include <hub/hub.h>

#if defined(CLIENT_ACC)
#define NAME "cclienta"
#define TAG  "CCNA"
#elif defined(CLIENT_CARD)
#define NAME "cclientc"
#define TAG  "CCNC"
#else
#define NAME "cclient"
#define TAG  "CCNT"
#endif

int main(void)
{
    int *count;
    char big[HUB_CMD_MAX + 8];

    if (!hub_present()) {
        printf(NAME ": no hub\r\n");

        return 0;
    }

    count = hub_block(TAG, sizeof *count);
    if (count == NULL) {
        printf(NAME ": no block\r\n");

        return 0;
    }

    ++*count;
    printf(NAME " %d: last %d, failed %d, depth %d, resumed %d\r\n", *count,
           hub_last_result(), hub_failed_job(), hub_depth(), hub_resumed());

    if (*count >= 5) {
        printf(NAME " done\r\n");

        return 0;
    }

    hub_enter(TAG);
    if (*count == 3) {
        hub_push("fail", HUB_STOP_ON_ERROR);
        hub_push("Echo " NAME "-not-run", 0);
    } else {
        hub_push("Echo " NAME "-job", HUB_STOP_ON_ERROR);
    }

    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = '\0';
    if (hub_push(big, 0) != HUB_ERR_TOO_LONG) {
        printf(NAME ": a long command was accepted\r\n");
    }

    hub_return_to(NAME);

    return 0;
}
