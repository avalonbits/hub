/*
 * cclient: a hub client in C, testing include/hub.h and lib/hub_glue.s.
 *
 * Each run adds one to a counter kept in a hub block and prints it. Until
 * the counter reaches 5, it opens a frame with one job and itself as the
 * continuation. Run 3's job fails on purpose (stop on error), so run 4 --
 * that frame's continuation -- reports the failure; the other runs report
 * a clean frame. It also checks that an over-long command is refused.
 */
#include <stdio.h>
#include <string.h>

#include "hub.h"

int main(void)
{
    int *count;
    char big[HUB_CMD_MAX + 8];

    if (!hub_present()) {
        printf("cclient: no hub\r\n");

        return 0;
    }

    count = hub_block("CCNT", sizeof *count);
    if (count == NULL) {
        printf("cclient: no block\r\n");

        return 0;
    }

    ++*count;
    printf("cclient %d: last %d, failed %d, depth %d\r\n", *count,
           hub_last_result(), hub_failed_job(), hub_depth());

    if (*count >= 5) {
        printf("cclient done\r\n");

        return 0;
    }

    hub_enter("CCNT");
    if (*count == 3) {
        hub_push("fail", HUB_STOP_ON_ERROR);
        hub_push("Echo cclient-not-run", 0);
    } else {
        hub_push("Echo cclient-job", HUB_STOP_ON_ERROR);
    }

    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = '\0';
    if (hub_push(big, 0) != HUB_ERR_TOO_LONG) {
        printf("cclient: a long command was accepted\r\n");
    }

    hub_return_to("cclient");

    return 0;
}
