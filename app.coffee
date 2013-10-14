#!/usr/bin/env coffee

## Module dependencies

  coffee         = require 'coffee-script'
  express        = require 'express'
  fs             = require 'fs'
  less           = require 'less'
  util           = require 'util'
  routes_main    = require './routes/index'
  routes_results = require './routes/results'
  conf           = require "#{__dirname}/conf/main.conf"

## Configure the app

  app = module.exports = express()

  app.configure ->

    ## eco doesn't work with Express 3 yet and express 3 has dropped layouts. This is a bit hackish but works
    app.engine 'eco', (path, options, fn) ->
      fs.readFile path, 'utf8', (err, inner_eco) ->
        return fn err if err
        fs.readFile path.replace(/^(.+)\/.*/,'$1/layout.eco'), 'utf8', (err, outer_eco) ->
          return fn err if err
          html = require('eco').render inner_eco+outer_eco, options
          fn null, html 

    app.set k,v for k,v of {
      'views':  "#{__dirname}/views"
      'view engine':  'eco'
      'view options':  layout: true
    }
    app.use item for item in [
      express.bodyParser()
      express.cookieParser()
      express.methodOverride()
      app.router
      express.static "#{__dirname}/public", maxAge: 3600*1000
    ]

  app.configure 'development', () ->
    app.use item for item in [
      express.logger()
      express.errorHandler
        dumpExceptions: true
        showStack: true
    ]

  app.configure 'production', () ->
    app.use item for item in [
      express.logger()
      app.use express.errorHandler()
    ]

## Remove slashes from the end of URLs

  app.get /.\/$/, ( req, res ) -> res.redirect 302, req.url.replace( /^(.+)\/$/, '$1' )

## Base pages

  app.get /^\/(test|about|privacy|optout)?$/, ( req, res ) ->
    view = req.url.replace('/','').replace /\?.*/,''
    view = 'index' if view.length == 0
    routes_main[view] req, res

## Submit an email address

  app.post '/', routes_main.submit

## Submit an opt-out

  app.post '/optout', routes_main.optout

## Display information about a test

  app.get  "/test/:name", routes_main.test

## Display results page sans-JS

  app.get  "#{conf.site.path}:lookupCode([0-9a-f]{16})/meta/:emailLogId([0-9]+)/:callbackId([0-9]+)", routes_results.metaRefresh
  app.get  "#{conf.site.path}:lookupCode([0-9a-f]{16})", routes_results.getResultsHTML

## Display results page with-JS

  app.post "#{conf.site.path}:lookupCode([0-9a-f]{16})", routes_results.getResultsHTML
  app.get  "#{conf.site.path}:lookupCode([0-9a-f]{16})/ajax/:emailLogId([0-9]+)/:callbackId([0-9]+)", routes_results.getResultsAJAX

## Callbacks

  app.post "#{conf.site.path}emailStatusCB/:callbackCode([0-9a-f]{16})",    routes_results.emailStatusCallback
  app.get  "#{conf.site.path}cb/:callbackCode([0-9a-f]{16})/:name",         routes_results.testCallback
  app.post "#{conf.site.path}cb/:callbackCode([0-9a-f]{16})/:name",         routes_results.testCallback
  app.get  "#{conf.site.path}cb/:callbackCode([0-9a-f]{16})/:name/:ignore", routes_results.testCallback

  app.get "/foo/:lookupCode",  routes_results.foo

## .js (Reads .coffee, compiles to javascript)

  app.get /(.+)\.js$/, ( req, res ) ->
    path = "#{__dirname}/public#{req.params[0]}";

    fs.readFile "#{path}.js", 'ascii', ( err, data ) ->
      if err
        fs.readFile "#{path}.coffee", 'ascii', ( err, data ) ->
          if err
            res.set 'Content-Type', 'text/plain'
            res.send 404, 'Not found'
          else
            res.set 'Content-Type', 'application/x-javascript'
            res.send coffee.compile data
      else
        res.set 'Content-Type', 'application/x-javascript'
        res.send data

## .css

  app.get /^(.+)\.css$/, ( req, res ) ->
    path = "#{__dirname}/public#{req.params[0]}";

    fs.readFile "#{path}.css", 'ascii', ( err, data ) ->
      if err
        fs.readFile "#{__dirname}/public#{req.params[0]}.less", 'ascii', ( err, data ) ->
          if err
            res.set 'Content-Type', 'text/plain'
            res.send 404, 'Not found'
          else
            less.render data, compress: true, (err,css) ->
              if err
                res.set 'Content-Type', 'text/plain'
                res.send 500, "Internal Server Error: #{err.message}"
              else
                res.set 'Content-Type', 'text/css'
                res.send css
      else
        res.set 'Content-Type', 'text/css'
        res.send data

## Send HTTP cache headers

  sendCacheHeaders = ( res, seconds ) ->
    res.set 'Cache-Control', "max-age=#{seconds}, public"
    res.set 'Expires', new Date( Date.now() + seconds * 1000 ).toUTCString()


## Start Listening

  server = app.listen conf.site.port

  if server.address()
    console.log "Express server listening on port %d in %s mode", server.address().port, app.settings.env
  else
    console.log "Failed to bind to port"
    process.exit 1
