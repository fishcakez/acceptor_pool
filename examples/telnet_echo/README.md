telnet_echo
===========

An OTP application

Run
---

Start the rebar3 shell and open a telnet session to the printed port.
`gen_server:stop(telnet_echo_socket).` will close and re-open the listen socket.
Any open telnet sessions will be gracefully closed without stopping the pool or
other connections.

    $ rebar3 shell
