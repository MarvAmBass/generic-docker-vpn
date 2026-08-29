/*
 * tun-helper: create the named TUN interface from /dev/net/tun, drop root,
 * and exec the given command with WG_TUN_FD pointing at the inherited
 * descriptor. This keeps every capability-requiring step in the entrypoint
 * while the WireGuard daemon itself runs fully unprivileged.
 *
 * usage: tun-helper <ifname> <user> <cmd> [args...]
 */
#include <fcntl.h>
#include <grp.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <ifname> <user> <cmd> [args...]\n", argv[0]);
    return 2;
  }
  const char *ifname = argv[1];
  const char *user = argv[2];

  struct passwd *pw = getpwnam(user);
  if (!pw) {
    fprintf(stderr, "tun-helper: unknown user %s\n", user);
    return 1;
  }
  if (pw->pw_uid == 0) {
    fprintf(stderr, "tun-helper: refusing to run the daemon as root\n");
    return 1;
  }

  int fd = open("/dev/net/tun", O_RDWR);
  if (fd < 0) {
    perror("tun-helper: open /dev/net/tun");
    return 1;
  }

  struct ifreq ifr;
  memset(&ifr, 0, sizeof(ifr));
  ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
  strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    perror("tun-helper: TUNSETIFF");
    return 1;
  }

  /* Pre-set the MTU to wireguard-go's device.DefaultMTU while still root:
   * the unprivileged daemon cannot SIOCSIFMTU, and its patched fd-handoff
   * path accepts an already-correct MTU. The entrypoint applies the config's
   * real MTU afterwards via the netlink-monitored interface. */
  int mtu_sock = socket(AF_INET, SOCK_DGRAM, 0);
  if (mtu_sock < 0) {
    perror("tun-helper: socket");
    return 1;
  }
  struct ifreq mtu_ifr;
  memset(&mtu_ifr, 0, sizeof(mtu_ifr));
  strncpy(mtu_ifr.ifr_name, ifname, IFNAMSIZ - 1);
  mtu_ifr.ifr_mtu = 1420;
  if (ioctl(mtu_sock, SIOCSIFMTU, &mtu_ifr) < 0) {
    perror("tun-helper: SIOCSIFMTU");
    return 1;
  }
  close(mtu_sock);

  if (setgroups(0, NULL) < 0 || setgid(pw->pw_gid) < 0 || setuid(pw->pw_uid) < 0) {
    perror("tun-helper: drop privileges");
    return 1;
  }
  if (setuid(0) == 0) {
    fprintf(stderr, "tun-helper: privilege drop did not stick\n");
    return 1;
  }

  char fdbuf[16];
  snprintf(fdbuf, sizeof(fdbuf), "%d", fd);
  if (setenv("WG_TUN_FD", fdbuf, 1) < 0 ||
      setenv("WG_PROCESS_FOREGROUND", "1", 1) < 0) {
    perror("tun-helper: setenv");
    return 1;
  }

  execvp(argv[3], &argv[3]);
  perror("tun-helper: exec");
  return 1;
}
