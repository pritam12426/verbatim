#ifndef VERBATIM_ROUTES_H
#define VERBATIM_ROUTES_H

#include "http_server.h"

/* Each handler writes its full response directly to fd. */
void route_speak(int fd, const HttpRequest *req, const ServerConfig *config, const char *client_ip);
void route_stop(int fd, const HttpRequest *req, const char *client_ip);
void route_status(int fd, const HttpRequest *req, const char *client_ip);
void route_voices(int fd, const HttpRequest *req, const char *client_ip);
void route_not_found(int fd);

#endif /* VERBATIM_ROUTES_H */
