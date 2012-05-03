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

  app = module.exports = express.createServer()

  app.configure ->
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

  app.get /.\/$/, ( req, res ) -> res.redirect req.url.replace( /^(.+)\/$/, '$1' ), 302

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

  app.post "#{conf.site.path}emailStatusCB/:callbackCode([0-9a-f]{16})", routes_results.emailStatusCallback
  app.get  "#{conf.site.path}cb/:callbackCode([0-9a-f]{16})/:name",      routes_results.testCallback
  app.post "#{conf.site.path}cb/:callbackCode([0-9a-f]{16})/:name",      routes_results.testCallback

  app.get "/foo/:lookupCode",  routes_results.foo

## .coffee (TODO:REMOVE THIS BEFORE GOING LIVE)

  app.get /(.+)\.coffee$/, ( req, res ) ->
    path = "#{__dirname}/public#{req.params[0]}.coffee";
    fs.readFile path, 'ascii', ( err, data ) ->
      res.header 'Content-Type', 'text/plain'
      if err
        res.send 'Not found', 404
      else
        res.send data

## Serve HTC files with the correct content-type

  app.get /(.+\.htc)$/, ( req, res ) ->
    path = "#{__dirname}/public#{req.params[0]}";
    console.log "Fetching #{path}"
    fs.readFile path, 'ascii', ( err, data ) ->
      if err
        res.header 'Content-Type', 'text/plain'
        res.send 'Not found', 404
      else
        sendCacheHeaders res, 600
        res.header 'Content-Type', 'text/x-component'
        res.send data

## .js (Reads .coffee, compiles to javascript)

  app.get /(.+)\.js$/, ( req, res ) ->
    path = "#{__dirname}/public#{req.params[0]}";

    fs.readFile "#{path}.js", 'ascii', ( err, data ) ->
      if err
        fs.readFile "#{path}.coffee", 'ascii', ( err, data ) ->
          if err
            res.header 'Content-Type', 'text/plain'
            res.send 'Not found', 404
          else
            ## TODO: Send the correct content-type header
            res.header 'Content-Type', 'text/plain'
            #res.header 'Content-Type', 'application/x-javascript'
            res.send coffee.compile data
      else
        res.header 'Content-Type', 'application/x-javascript'
        res.send data

## .css

  app.get /^(.+)\.css$/, ( req, res ) ->
    fs.readFile "#{__dirname}/public#{req.params[0]}.less", 'ascii', ( err, data ) ->
      if err
        res.header 'Content-Type', 'text/plain'
        res.send 'Not found', 404
      else
        less.render data, compress: true, (err,css) ->
          if err
            res.header 'Content-Type', 'text/plain'
            res.send "Internal Server Error: #{err.message}", 500
          else
            res.header 'Content-Type', 'text/css'
            res.send css

## Send HTTP cache headers

  sendCacheHeaders = ( res, seconds ) ->
    res.header 'Cache-Control', "max-age=#{seconds}, public"
    res.header 'Expires', new Date( Date.now() + seconds * 1000 ).toUTCString()


## Start Listening

  app.listen 3000

  if app.address()
    console.log "Express server listening on port %d in %s mode", app.address().port, app.settings.env
  else
    console.log "Failed to bind to port"
    process.exit 1
