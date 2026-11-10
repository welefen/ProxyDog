#include "ProcessProbe.h"

#include <arpa/inet.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <stdlib.h>
#include <string.h>

int proxydog_parent_pid(int pid) {
    if (pid <= 0) {
        return 0;
    }
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int got = proc_pidinfo((pid_t)pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (got != (int)sizeof(info)) {
        return 0;
    }
    return (int)info.pbi_ppid;
}

int proxydog_process_for_local_port(unsigned short port,
                                    int *pid,
                                    char *name,
                                    int name_len,
                                    char *path,
                                    int path_len) {
    if (pid == NULL) {
        return -1;
    }
    *pid = 0;

    int count = proc_listallpids(NULL, 0);
    if (count <= 0) {
        return -1;
    }
    pid_t *pids = calloc((size_t)count + 32, sizeof(pid_t));
    if (pids == NULL) {
        return -1;
    }
    count = proc_listallpids(pids, (int)((count + 32) * sizeof(pid_t)));
    if (count <= 0) {
        free(pids);
        return -1;
    }

    for (int i = 0; i < count; i++) {
        pid_t process = pids[i];
        if (process <= 0) {
            continue;
        }
        int fdsize = proc_pidinfo(process, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fdsize <= 0) {
            continue;
        }
        struct proc_fdinfo *fds = malloc((size_t)fdsize);
        if (fds == NULL) {
            continue;
        }
        int used = proc_pidinfo(process, PROC_PIDLISTFDS, 0, fds, fdsize);
        if (used <= 0) {
            free(fds);
            continue;
        }
        int fd_count = used / (int)sizeof(struct proc_fdinfo);
        for (int j = 0; j < fd_count; j++) {
            if (fds[j].proc_fdtype != PROX_FDTYPE_SOCKET) {
                continue;
            }
            struct socket_fdinfo info;
            memset(&info, 0, sizeof(info));
            int got = proc_pidfdinfo(process, fds[j].proc_fd, PROC_PIDFDSOCKETINFO,
                                     &info, sizeof(info));
            if (got != (int)sizeof(info)) {
                continue;
            }
            if (info.psi.soi_kind != SOCKINFO_TCP) {
                continue;
            }
            if (info.psi.soi_family != AF_INET && info.psi.soi_family != AF_INET6) {
                continue;
            }
            unsigned short local_port = ntohs((unsigned short)(
                info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport & 0xFFFF));
            if (local_port != port) {
                continue;
            }

            *pid = (int)process;
            if (name != NULL && name_len > 0) {
                memset(name, 0, (size_t)name_len);
                proc_name(process, name, name_len);
            }
            if (path != NULL && path_len > 0) {
                memset(path, 0, (size_t)path_len);
                proc_pidpath(process, path, (uint32_t)path_len);
            }
            free(fds);
            free(pids);
            return 0;
        }
        free(fds);
    }
    free(pids);
    return 1;
}
