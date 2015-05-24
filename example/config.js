module.exports =
{
    port: 1337,
    redis: { port: 6379 },
    mysql:
    {
        username: 'example',
        password: 'password',
        database: 'cool_project'
    },
    session: { secret: 'a secret for generating session IDs' },

    // Path to static files
    static: __dirname + '/static',

    // Path to views
    views: __dirname + '/views'
};
