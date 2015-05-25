module.exports =
{
    port: 1337,
    redis: { port: 6379 },
    session: { secret: 'a secret for generating session IDs' },
    mysql:
    {
        username: 'example',
        password: 'password',
        database: 'cool_project'
    },
    
    login:
    {
        app_id: 'sign up @ login.wetfish.net',
        app_secret: 'to generate these'
    },

    // Path to static files
    static: __dirname + '/static',

    // Path to views
    views: __dirname + '/views'
};
