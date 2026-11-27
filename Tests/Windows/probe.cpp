#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdlib>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 2;
    SOCKET connection = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (connection == INVALID_SOCKET) return 2;
    sockaddr_in endpoint{};
    endpoint.sin_family = AF_INET;
    endpoint.sin_port = htons(static_cast<unsigned short>(std::atoi(argv[1])));
    endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const int result = connect(connection, reinterpret_cast<sockaddr*>(&endpoint), sizeof(endpoint));
    closesocket(connection);
    WSACleanup();
    return result == 0 ? 0 : 1;
}
