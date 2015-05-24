// Start the server
var config = require('./config');
var server = require('../server').createServer(config);

// Add a custom model
require('./models/example')(server.model);

// Add some routes
require('./routes/pages')(server);
