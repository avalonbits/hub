/*
 * rep: run a command a number of times, and count how often it failed.
 *
 *     rep 10 mytest
 *
 * What it shows: a program that chains to itself. Each run queues the
 * command once more, with "rep -r" as the continuation, and keeps its count
 * in a block between runs; the continuation reads the command's result with
 * hub_last_result(). Because the frame closes as its continuation starts,
 * this goes on for as many rounds as asked without nesting any deeper.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hub/hub.h>

/* A failure's result. Not 1: MOS reports a program's 1, 4 or 5 as its own
 * "Invalid command", and stops an autoexec.txt or obey file there. */
#define FAILED 100

#define TAG "REP "

struct rep_state {
    unsigned size;                      /* sizeof(struct rep_state) */
    int runs;                           /* asked for */
    int done;                           /* run so far */
    int failed;                         /* of those, how many failed */
    char cmd[HUB_CMD_MAX + 1];
};

/* Queue one more run of the command, and this program after it. */
static int round_again(struct rep_state *s)
{
    if (hub_enter(TAG) != HUB_OK || hub_push(s->cmd, 0) != HUB_OK
        || hub_return_to("rep -r") != HUB_OK) {
        printf("rep: hub can't take more work\r\n");

        return FAILED;
    }

    return 0;
}

static int start(int argc, char **argv)
{
    struct rep_state *s;
    int i;

    if (argc < 3 || atoi(argv[1]) < 1) {
        printf("usage: rep <times> <command>\r\n");

        return FAILED;
    }
    s = hub_block(TAG, sizeof *s);
    if (s == NULL) {
        printf("rep: hub has no room for its state\r\n");

        return FAILED;
    }
    s->cmd[0] = '\0';
    for (i = 2; i < argc; i++) {
        if (strlen(s->cmd) + strlen(argv[i]) + 1 > HUB_CMD_MAX) {
            printf("rep: the command is longer than %d characters\r\n", HUB_CMD_MAX);

            return FAILED;
        }
        if (i > 2) {
            strcat(s->cmd, " ");
        }
        strcat(s->cmd, argv[i]);
    }
    s->size = sizeof *s;
    s->runs = atoi(argv[1]);
    s->done = 0;
    s->failed = 0;

    return round_again(s);
}

/* The continuation: count the run that just ended, then go again or stop. */
static int next(void)
{
    struct rep_state *s = hub_block(TAG, sizeof *s);

    if (s == NULL || s->size != sizeof *s) {
        printf("rep: nothing to carry on with\r\n");

        return 0;
    }
    s->done++;
    if (hub_last_result() != 0) {
        s->failed++;
    }
    if (s->done < s->runs && !hub_resumed()) {
        return round_again(s);
    }
    printf("rep: %d run%s, %d failed\r\n", s->done, s->done == 1 ? "" : "s", s->failed);

    return 0;
}

int main(int argc, char **argv)
{
    if (!hub_present()) {
        printf("rep: needs hub\r\n");

        return FAILED;
    }
    if (argc == 2 && strcmp(argv[1], "-r") == 0) {
        return next();
    }

    return start(argc, argv);
}
