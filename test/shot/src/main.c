/*
 * shot: a hub client that checks the user screen on a real VDP, for
 * test/screen.sh. Run under hub:
 *
 *   shot p [m]  queue "shot d [m]" as a user program (HUB_USER_PROGRAM |
 *            HUB_PAUSE_AFTER), with "shot c" as the continuation.
 *   shot d [m]  the user program: note the text rows it starts with -- which
 *            say which font it got -- then switch to mode m if given, fill a
 *            red rectangle, and leave the graphics origin moved and pixel
 *            coordinates on, as a program might.
 *   shot c   note the rows it starts with, clear the screen, read a pixel
 *            inside where the rectangle was, draw HUB_SCREEN_BUFFER back at
 *            0,0 and read the same pixel again; write hub_user_screen, the
 *            mode, both programs' rows and both pixels to /shot.txt.
 *   shot f   make an 8x16 font in buffer 100, from an empty buffer, for a
 *            boot script to select. Works without hub.
 *
 * Pixels are read back with VDU 23,0,&84, which answers through MOS's
 * sysvars (sysvar_scrpixel, flagged in sysvar_vdp_pflags).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <agon/mos.h>
#include <hub/hub.h>

#define PFLAGS      0x04
#define PFLAG_POINT 0x04
#define PFLAG_MODE  0x10
#define SCRPIXEL    0x0A
#define SCRROWS     0x14
#define SCRMODE     0x27

static volatile uint8_t *sv;

static void w16(int v)
{
    putch(v & 0xff);
    putch((v >> 8) & 0xff);
}

/* The colour at x, y (logical coordinates) as 0xRRBBGG, or 0xFFFFFF if the
 * VDP doesn't answer. */
static unsigned long pixel(int x, int y)
{
    long i;

    sv[PFLAGS] &= ~PFLAG_POINT;
    putch(23);
    putch(0);
    putch(0x84);
    w16(x);
    w16(y);
    for (i = 0; i < 200000 && !(sv[PFLAGS] & PFLAG_POINT); i++) {
    }
    if (!(sv[PFLAGS] & PFLAG_POINT)) {
        return 0xFFFFFFUL;
    }

    return (unsigned long) sv[SCRPIXEL] << 16 | (unsigned long) sv[SCRPIXEL + 1] << 8
           | sv[SCRPIXEL + 2];
}

/* The text rows, after asking the VDP for its mode and geometry (VDU
 * 23,0,&86), which a font selection changes too. */
static int rows(void)
{
    long i;

    sv[PFLAGS] &= ~PFLAG_MODE;
    putch(23);
    putch(0);
    putch(0x86);
    for (i = 0; i < 200000 && !(sv[PFLAGS] & PFLAG_MODE); i++) {
    }

    return sv[SCRROWS];
}

static void make_font(void)
{
    putch(23);                  /* buffer 100: create, 256 * 16 bytes */
    putch(0);
    putch(0xA0);
    w16(100);
    putch(3);
    w16(256 * 16);
    putch(23);                  /* font from it: 8x16, ascent 12 */
    putch(0);
    putch(0x95);
    putch(1);
    w16(100);
    putch(8);
    putch(16);
    putch(12);
    putch(0);
}

static void queue(const char *mode)
{
    char cmd[16];

    snprintf(cmd, sizeof cmd, "shot d %s", mode);
    hub_enter("SHOT");
    hub_push(cmd, HUB_USER_PROGRAM | HUB_PAUSE_AFTER);
    hub_return_to("shot c");
}

static void draw(const char *mode)
{
    unsigned char *started = hub_block("SHOT", 1);

    if (started != NULL) {
        *started = (unsigned char) rows();
    }
    if (*mode != '\0') {
        putch(22);
        putch(atoi(mode));
    }
    putch(18);                  /* GCOL 0, 9: red */
    putch(0);
    putch(9);
    putch(25);                  /* MOVE 100, 100 */
    putch(4);
    w16(100);
    w16(100);
    putch(25);                  /* PLOT 101: fill to 1200, 950 */
    putch(101);
    w16(1200);
    w16(950);
    printf("shot: drawn\r\n");

    putch(29);                  /* origin to the middle */
    w16(640);
    w16(512);
    putch(23);                  /* pixel coordinates: logical scaling off */
    putch(0);
    putch(0xC0);
    putch(0);
}

static void check(void)
{
    unsigned long cleared, back;
    int mode = hub_user_screen();
    int now = rows();
    unsigned char *started = hub_block("SHOT", 1);
    FILE *f;

    putch(23);                  /* logical coordinates, origin 0,0 */
    putch(0);
    putch(0xC0);
    putch(1);
    putch(29);
    w16(0);
    w16(0);
    putch(12);                  /* CLS */
    putch(16);                  /* CLG */
    cleared = pixel(300, 300);

    putch(23);                  /* select HUB_SCREEN_BUFFER */
    putch(27);
    putch(0x20);
    w16(HUB_SCREEN_BUFFER);
    putch(23);                  /* draw it at 0,0 */
    putch(27);
    putch(3);
    w16(0);
    w16(0);
    back = pixel(300, 300);

    f = fopen("/shot.txt", "w");
    if (f != NULL) {
        fprintf(f, "user screen %d, mode %d, rows %d/%d, cleared %06lx, back %06lx\n",
                mode, sv[SCRMODE], started != NULL ? *started : -1, now, cleared, back);
        fclose(f);
    }
}

int main(int argc, char **argv)
{
    const char *mode;

    sv = mos_sysvars();
    if (argc > 1 && argv[1][0] == 'f') {
        make_font();

        return 0;
    }
    if (!hub_present() || argc < 2) {
        printf("shot: no hub\r\n");

        return 0;
    }

    mode = argc > 2 ? argv[2] : "";
    switch (argv[1][0]) {
    case 'p':
        queue(mode);
        break;
    case 'd':
        draw(mode);
        break;
    case 'c':
        check();
        break;
    }

    return 0;
}
