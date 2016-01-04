module.exports =
{
    // The port your server will run on
    port: 1337,

    // Path to static files
    static: __dirname + '/../public',

    // Path to views
    views: __dirname + '/views',

    // SSL configuration
    ssl:
    {
        enabled: false,
        key: 'path/to/private.key',
        cert: 'path/to/cert'
    }

    /*
    Before enabling the following options, you'll need to install the required dependencies
    
    // Options to enable saving user sessions
    session:
    {
        driver: 'redis',
        secret: 'a secret for generating session IDs'
    },

    // Redis connection info
    redis: { port: 6379 },

    // MySQL connection info
    mysql:
    {
        username: 'example',
        password: 'password',
        database: 'cool_project'
    },

    // Wetfish Login info
    login:
    {
        app_id: 'sign up @ login.wetfish.net',
        app_secret: 'to generate these'
    },
    */
};
