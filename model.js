var redis, mysql;

var model =
{
    // Function to connect to our databases
    connect: function(config)
    {
        model.config = config;

        if(config.redis)
        {
            redis = require('redis');
            model.connect_redis(config);
        }

        if(config.mysql)
        {
            mysql = require('mysql');
            model.connect_mysql(config);
        }
    },

    connect_redis: function(config)
    {
        // Main redis connection
        model.redis = redis.createClient(config.redis.port);

        // Redis connection for IPC
        model.redisIPC = redis.createClient(config.redis.port);
    },

    connect_mysql: function(config)
    {
        var options =
        {
            host     : (config.mysql.host || 'localhost'),
            user     : config.mysql.username,
            password : config.mysql.password,
            database : config.mysql.database,
            timezone : 'utc'
        };
        
        // MySQL connection
        model.mysql = mysql.createConnection(options);
        model.mysql.connect();
    },

}

module.exports = model;
