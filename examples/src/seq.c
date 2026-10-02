/*
 * seq: run commands one after another, stopping at the first that fails.
 *
 *     seq acc -c a.c ; acc -c b.c ; acc a.o b.o -o prog.bin
 *
 * Up to seven commands, separated by ';'. When they have run, seq comes back
 * and says either that they all worked or which one failed, with what result.
 *
 * What it shows: a frame of jobs pushed with HUB_STOP_ON_ERROR, a
 * continuation that brings the program back, and hub_failed_job() and
 * hub_last_result() read in that continuation. The commands are kept in a
 * block, so the continuation can name the one that failed.
 */
#include <stdio.h>
#include <string.h>

#include <hub/hub.h>

/* A failure's result. Not 1: MOS reports a program's 1, 4 or 5 as its own
 * "Invalid command", and stops an autoexec.txt or obey file there. */
#define FAILED 100

#define TAG      "SEQ "
#define MAX_CMDS (HUB_MAX_JOBS - 1)     /* one slot is the continuation's */

struct seq_state {
    unsigned size;                      /* sizeof(struct seq_state): see below */
    int count;
    char cmd[MAX_CMDS][HUB_CMD_MAX + 1];
};

/* The block from an earlier run, or a fresh one. The size field tells a block
 * this version of seq wrote from one an older version left with another
 * shape: hub keeps a block's bytes, and grows it, whatever the program asks. */
static struct seq_state *state(void)
{
    return hub_block(TAG, sizeof(struct seq_state));
}

/* Split the arguments, rejoined with spaces, at each ';'. */
static int split(struct seq_state *s, int argc, char **argv)
{
    char *cmd = s->cmd[0];
    int i;

    s->count = 0;
    cmd[0] = '\0';
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], ";") == 0) {
            if (cmd[0] != '\0') {
                if (++s->count == MAX_CMDS) {
                    return -1;
                }
                cmd = s->cmd[s->count];
                cmd[0] = '\0';
            }
            continue;
        }
        if (strlen(cmd) + strlen(argv[i]) + 1 > HUB_CMD_MAX) {
            return -2;
        }
        if (cmd[0] != '\0') {
            strcat(cmd, " ");
        }
        strcat(cmd, argv[i]);
    }
    if (cmd[0] != '\0') {
        s->count++;
    }

    return s->count;
}

static int start(int argc, char **argv)
{
    struct seq_state *s = state();
    int n, i;

    if (s == NULL) {
        printf("seq: hub has no room for its state\r\n");

        return FAILED;
    }
    n = split(s, argc, argv);
    if (n == -1) {
        printf("seq: at most %d commands\r\n", MAX_CMDS);

        return FAILED;
    }
    if (n == -2) {
        printf("seq: a command is longer than %d characters\r\n", HUB_CMD_MAX);

        return FAILED;
    }
    if (n == 0) {
        printf("usage: seq <command> ; <command> ...\r\n");

        return FAILED;
    }
    s->size = sizeof *s;

    if (hub_enter(TAG) != HUB_OK) {
        printf("seq: frames nested too deep\r\n");

        return FAILED;
    }
    for (i = 0; i < n; i++) {
        if (hub_push(s->cmd[i], HUB_STOP_ON_ERROR) != HUB_OK) {
            printf("seq: hub's queue is full\r\n");

            return FAILED;
        }
    }
    hub_return_to("seq -r");

    return 0;                           /* hub runs the commands now */
}

/* The continuation: say how it went, and fail if a command did -- run by
 * another program, seq then fails as a job of its frame. */
static int report(void)
{
    struct seq_state *s = state();
    int failed = hub_failed_job();

    if (s == NULL || s->size != sizeof *s) {
        printf("seq: nothing to report\r\n");

        return 0;
    }
    if (failed < 0) {
        printf("seq: %d command%s done\r\n", s->count, s->count == 1 ? "" : "s");

        return 0;
    }
    printf("seq: command %d (%s) failed with %d%s\r\n", failed + 1, s->cmd[failed],
           hub_last_result(), hub_resumed() ? ", cut short by a reset" : "");

    return FAILED;
}

int main(int argc, char **argv)
{
    if (!hub_present()) {
        printf("seq: needs hub\r\n");

        return FAILED;
    }
    if (argc == 2 && strcmp(argv[1], "-r") == 0) {
        return report();
    }

    return start(argc, argv);
}
