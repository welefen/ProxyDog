#ifndef PROCESS_PROBE_H
#define PROCESS_PROBE_H

/// Resolves the process that owns a TCP socket with the given local port.
///
/// Uses libproc to enumerate all processes and their TCP sockets, which works for
/// other processes of the same user without any extra permission. Root-owned helper
/// processes may not be visible.
///
/// - Returns: 0 when a process was found (pid/name/path filled), 1 when nothing matched,
///            a negative value on error.
int proxydog_process_for_local_port(unsigned short port,
                                    int *pid,
                                    char *name,
                                    int name_len,
                                    char *path,
                                    int path_len);

/// Parent pid of a process (used to walk up from helper processes to their app bundle).
///
/// - Returns: ppid (> 0) on success, 0 when unknown.
int proxydog_parent_pid(int pid);

#endif /* PROCESS_PROBE_H */
