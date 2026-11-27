#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) return 2;
    const bool ipv6 = argc == 3 && !std::strcmp(argv[2], "ipv6");
    const bool udp = argc == 3 && !std::strcmp(argv[2], "udp");
    if (argc == 3 && !ipv6 && !udp) return 2;
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 2;
    const int family = ipv6 ? AF_INET6 : AF_INET;
    SOCKET connection = socket(family, udp ? SOCK_DGRAM : SOCK_STREAM, udp ? IPPROTO_UDP : IPPROTO_TCP);
    if (connection == INVALID_SOCKET) return 2;
    sockaddr_storage storage{};
    if (ipv6) {
        auto& endpoint = reinterpret_cast<sockaddr_in6&>(storage);
        endpoint.sin6_family = AF_INET6;
        endpoint.sin6_port = htons(static_cast<unsigned short>(std::atoi(argv[1])));
        InetPtonA(AF_INET6, "::1", &endpoint.sin6_addr);
    } else {
        auto& endpoint = reinterpret_cast<sockaddr_in&>(storage);
        endpoint.sin_family = AF_INET;
        endpoint.sin_port = htons(static_cast<unsigned short>(std::atoi(argv[1])));
        endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    }
    const auto* endpoint = reinterpret_cast<sockaddr*>(&storage);
    const int length = ipv6 ? sizeof(sockaddr_in6) : sizeof(sockaddr_in);
    const int result = udp ? sendto(connection, "t", 1, 0, endpoint, length)
                           : connect(connection, endpoint, length);
    closesocket(connection);
    WSACleanup();
    return result == (udp ? 1 : 0) ? 0 : 1;
}
