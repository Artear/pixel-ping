# Require Node.js core modules.
fs          = require 'fs'
url         = require 'url'
http        = require 'http'
https        = require 'https'
querystring = require 'querystring'

#### The Pixel Ping server

# Keep the version number in sync with `package.json`.
VERSION = '0.1.4'

# Regular expression for HTTPS addresses
httpsPattern = new RegExp('^https://', 'i');

# The in-memory hit `store` is just a hash. We map unique identifiers to the
# number of hits they receive here, and flush the `store` every `interval`
# seconds.
store = {}

# Record a single incoming hit from the remote pixel.
record = (params) ->
  return unless key = params.query?.key
  store[key] or= 0
  store[key] +=  1

# Serializes the current `store` to JSON, and creates a fresh one. Add a
# `secret` token to the request object, if configured.
serialize = ->
  data  = json: JSON.stringify(store)
  data.secret = config.secret if config.secret  
  querystring.stringify data

# Reset the `store`.
reset = ->
  store = {}

# Flushes the `store` to be saved by an external API. The contents of the store
# are sent to the configured `endpoint` URL via HTTP/HTTPS POST. If no `endpoint` is
# configured, this is a no-op.
flush = ->
  log store
  if !config.endpoint
    return
  else if httpsPattern.test(config.endpoint)
    endpointProtocol = https
  else 
    endpointProtocol = http
  data = serialize()
  endReqOpts['headers']['Content-Length'] = data.length
  request = endpointProtocol.request endReqOpts, (response) ->
    reset()
    console.info '--- flushed ---'
  request.on 'error', (e) ->
    reset() if config.discard
    console.log "--- cannot connect to endpoint : #{e.message}"
  request.write data
  request.end()

# Log the contents of the `store` to **stdout**. Happens on every flush, so that
# there's a record of hits if something goes awry.
log = (hash) ->
  for key, hits of hash
    console.info "#{hits}:\t#{key}"

#### Configuration

# Load the configuration and the contents of the tracking pixel. Handle requests
# for the version number, and usage information.
configPath  = process.argv[2]
if configPath in ['-v', '-version', '--version']
  console.log "Pixel Ping version #{VERSION}"
  process.exit 0
if not configPath or (configPath in ['-h', '-help', '--help'])
  console.error "Usage: pixel-ping path/to/config.json"
  process.exit 0
config      = JSON.parse fs.readFileSync(configPath).toString()
pixel       = fs.readFileSync __dirname + '/pixel.gif'

# HTTP/HTTPS headers for the pixel image.
pixelHeaders =
  'Cache-Control':        'private, no-cache, proxy-revalidate, max-age=0'
  'Content-Type':         'image/gif'
  'Content-Disposition':  'inline'
  'Content-Length':       pixel.length

# HTTP/HTTPS headers for the 404 response.
emptyHeaders =
  'Content-Type':   'text/html'
  'Content-Length': '0'

# If an `endpoint` has been configured, create an HTTP/HTTPS client connected to it,
# and log a warning otherwise.
if config.endpoint
  console.info "Flushing hits to #{config.endpoint}"
  endParams = url.parse config.endpoint
  endReqOpts =
    host: endParams.hostname
    port: endParams.port or 80
    method: 'POST'
    path: endParams.pathname
    headers:
      'host':         endParams.host
      'Content-Type': 'application/x-www-form-urlencoded'
else
  console.warn "No endpoint set. Hits won't be flushed, add \"endpoint\" to #{configPath}."

# Sending `SIGUSR2` to the Pixel Ping process will force a data flush.
process.on 'SIGUSR2', ->
  console.log 'Got SIGUSR2. Forcing a flush:'
  flush()

# Don't let exceptions kill the server.
process.on 'uncaughtException', (err) ->
  console.error "Uncaught Exception: #{err}"

# Determines the right protocol (HTTP/HTTPS) to be used on the nodejs server
if config.sslkey && config.sslcert && config.sslca
  protocol = https;
  protocolOptions = {
   key  : fs.readFileSync(config.sslkey),
   cert : fs.readFileSync(config.sslcert),
   ca   : fs.readFileSync(config.sslca),
  };
else if config.sslkey && config.sslcert
  protocol = https;
  protocolOptions = {
   key  : fs.readFileSync(config.sslkey),
   cert : fs.readFileSync(config.sslcert),
  };
else
  protocol = http;

# Create a `Server` object. When a request comes in, ensure that it's looking
# for `pixel.gif`. If it is, serve the pixel and record the request.
server = protocol.createServer protocolOptions, (req, res) ->
  params = url.parse req.url, true
  if params.pathname is '/pixel.gif'
    res.writeHead 200, pixelHeaders
    res.end pixel
    record params
  else
    res.writeHead 404, emptyHeaders
    res.end ''
  null

#### Startup

# Start the server listening for pixel hits, and begin the periodic data flush.
server.listen config.port, config.host
setInterval flush, config.interval * 1000
