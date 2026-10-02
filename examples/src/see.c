/*
 * see: run a program, then let its screen be seen again.
 *
 *     see bmpview /pics/cat.bmp
 *
 * The program runs on the screen hub's prompt has, whatever mode or font the
 * prompt was left in, and hub pauses after it so its output can be read.
 * Then see offers to show that screen again -- as Turbo Pascal's Alt-F5 did
 * -- for as long as you like, until Esc.
 *
 * What it shows: HUB_USER_PROGRAM, HUB_PAUSE_AFTER, and hub_user_screen()
 * with the VDP buffer HUB_SCREEN_BUFFER. Showing the screen again needs VDP
 * 2.2.0 or later; on an older VDP the buffer is empty.
 */
#include <stdio.h>
#include <string.h>

#include <agon/mos.h>
#include <hub/hub.h>

/* A failure's result. Not 1: MOS reports a program's 1, 4 or 5 as its own
 * "Invalid command", and stops an autoexec.txt or obey file there. */
#define FAILED 100

static void vdu_word(int v)
{
    putch(v & 0xFF);
    putch((v >> 8) & 0xFF);
}

/* Draw the captured screen at the top left, in its own mode. A mode change
 * drops the font back to the system one, so the mode is changed only when it
 * must be: hub ran the program in the prompt's mode, so the two differ only
 * if the program changed it. */
static void show(int mode, int prompt_mode)
{
    if (mode != prompt_mode) {
        putch(22);                      /* its mode, which also clears */
        putch(mode);
    } else {
        putch(12);                      /* CLS */
    }
    putch(23);                          /* logical coordinates */
    putch(0);
    putch(0xC0);
    putch(1);
    putch(23);                          /* select the buffer as a bitmap */
    putch(27);
    putch(0x20);
    vdu_word(HUB_SCREEN_BUFFER);
    putch(23);                          /* and draw it at 0,0 */
    putch(27);
    putch(3);
    vdu_word(0);
    vdu_word(0);
}

static int start(int argc, char **argv)
{
    char cmd[HUB_CMD_MAX + 1];
    int i;

    if (argc < 2) {
        printf("usage: see <program> [<arguments>]\r\n");

        return FAILED;
    }
    cmd[0] = '\0';
    for (i = 1; i < argc; i++) {
        if (strlen(cmd) + strlen(argv[i]) + 1 > HUB_CMD_MAX) {
            printf("see: the command is longer than %d characters\r\n", HUB_CMD_MAX);

            return FAILED;
        }
        if (i > 1) {
            strcat(cmd, " ");
        }
        strcat(cmd, argv[i]);
    }
    if (hub_enter("SEE ") != HUB_OK
        || hub_push(cmd, HUB_USER_PROGRAM | HUB_PAUSE_AFTER) != HUB_OK
        || hub_return_to("see -r") != HUB_OK) {
        printf("see: hub can't take more work\r\n");

        return FAILED;
    }

    return 0;
}

/* The continuation: hub has put the prompt's screen back. */
static int again(void)
{
    volatile uint8_t *sysvars = mos_sysvars();
    int prompt_mode = sysvars[0x27];   /* sysvar_scrMode */
    int mode = hub_user_screen();
    char key;

    printf("see: the program returned %d\r\n", hub_last_result());
    if (mode < 0) {
        printf("see: no screen was captured\r\n");

        return 0;
    }
    for (;;) {
        printf("see: Space shows its screen (mode %d), Esc ends\r\n", mode);
        key = getch();
        if (key == 27) {
            return 0;
        }
        if (key != ' ') {
            continue;
        }
        show(mode, prompt_mode);
        getch();
        if (mode != prompt_mode) {
            putch(22);                  /* back to the prompt's mode */
            putch(prompt_mode);
        } else {
            putch(12);
        }
    }
}

int main(int argc, char **argv)
{
    if (!hub_present()) {
        printf("see: needs hub\r\n");

        return FAILED;
    }
    if (argc == 2 && strcmp(argv[1], "-r") == 0) {
        return again();
    }

    return start(argc, argv);
}
