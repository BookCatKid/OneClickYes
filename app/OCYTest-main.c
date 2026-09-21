// Minimal unsigned test app used to trigger the Gatekeeper dialog.
// Proves it ran by writing /tmp/ocytest_LAUNCHED_<bundle-dir-name>.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char mark[1024] = "/tmp/ocytest_LAUNCHED";
    // argv[0] = .../OCYTest-NNNN.app/Contents/MacOS/OCYTest — use the bundle
    // dir name so each test copy has a unique marker.
    if (argc > 0 && argv[0]) {
        const char *dot = strstr(argv[0], ".app/");
        if (dot) {
            const char *base = dot;
            while (base > argv[0] && base[-1] != '/') base--;
            char name[256];
            size_t n = (size_t)(dot - base);
            if (n > 0 && n < sizeof(name)) {
                memcpy(name, base, n); name[n] = 0;
                snprintf(mark, sizeof(mark), "/tmp/ocytest_LAUNCHED_%s", name);
            }
        }
    }
    FILE *f = fopen(mark, "w");
    if (f) { fprintf(f, "launched pid=%d\n", getpid()); fclose(f); }
    sleep(3);
    return 0;
}
