# Lager AMQP Backend

This is a backend for the Lager Erlang logging framework.

[https://github.com/basho/lager](https://github.com/basho/lager)

It will send all of your logging messages to the exchange you specify and use the logging level 
as the routing key. It uses a smart connection pool to your broker. If the connection drops or 
becomes unusable, the backend will reconnect.

### Usage

Include this backend into your project using rebar:

    {lager_amqp_backend, ".*", {git, "https://github.com/jbrisbin/lager_amqp_backend.git", "master"}}

### Configuration

You can pass the backend the following configuration (shown are the defaults):

    {lager, [
      {handlers, [
        {lager_amqp_backend, [
          {name,        "lager_amqp_backend"},
          {level,       debug},
          {exchange,    <<"lager_amqp_backend">>},
          {amqp_user,   <<"guest">>},
          {amqp_pass,   <<"guest">>},
          {amqp_vhost,  <<"/">>},
          {amqp_host,   "localhost"},
          {amqp_port,   5672}
        ]}
      ]}
    ]}

### License

Apache 2.0, just like everything else I do. :)