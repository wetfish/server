module.exports =
{
    createServer: function(config)
    {
        // Primary express dependencies
        var fs = require('fs');
        var express = require('express');
        var app = express();
        var http = require('http').createServer(app);
        var bodyParser = require('body-parser');

        if(config.ssl.enabled)
        {
            var ssl =
            {
                key: fs.readFileSync(config.ssl.key),
                cert: fs.readFileSync(config.ssl.cert)
            };

            http = require('https').createServer(ssl, app);
        }

        if(config.sockets.enabled)
        {
            var io = require('socket.io')(server);
        }

        // Event related dependences
        var extend = require('extend');
        var events = require('events');
        var event = new events.EventEmitter();

        // Start express web server
        http.listen(config.port);
        console.log("wetfish server started");

        var model = require('./model');

        // Connect to Redis and MySQL if configured
        model.connect(config);

        // Set up session if configured
        if(config.session)
        {
            var session = require('express-session');

            // Do we want to use redis for sessions?
            if(config.session.driver == 'redis')
            {
                var RedisStore = require('connect-redis')(session);

                app.use(session({
                    store: new RedisStore({client: model.redis}),
                    secret: config.session.secret
                }));
            }
        }
        
        app.use(bodyParser.json());
        app.use(bodyParser.urlencoded({ extended: true }));

        if(config.static)
        {
            app.use(express.static(config.static));
        }

        if(config.views)
        {
            app.set('views', config.views);
            app.set('view engine', 'hjs');
        
            // Helper events
            event.on('render', function(req, res, options)
            {
                var defaults =
                {
                    session: req.session,
                    partials:
                    {
                        head: 'partials/head',
                        header: 'partials/header',
                        foot: 'partials/foot'
                    }
                };

                // Deep combine our defaults with the requested options
                options = extend(true, defaults, options);
                res.render(options.view, options);
            });

            // Special handler for messages
            event.on('message', function(req, res, message)
            {
                message = (message || {type: ''});
                message.type = message.type.toLowerCase();
                
                if(message.type == 'success')
                {
                    message.class = 'success';
                    message.label = (message.label || 'Success!');
                }
                else if(message.type == 'error')
                {
                    message.class = 'danger';
                    message.label = (message.label || 'Error:');
                }
                else
                {
                    message.class = 'info';
                }

                var options =
                {
                    view: 'message',
                    message: message
                }
                
                event.emit('render', req, res, options);
            });
        }
        
        var server =
        {
            app: app,
            config: config,
            event: event,
            model: model
        };

        if(config.sockets.enabled)
        {
            server.io = io;
        }

        return server;
    }
}
