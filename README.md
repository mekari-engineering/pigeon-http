# Pigeon
Enhanced http client for ruby. Packed with retry mechanism, circuit breaker, and datadog monitoring.

## Installation
```
gem install pigeon-http
```

## Usage

### Basic Usage

```
require 'pigeon-http'

client = Pigeon::Client.new('http_request')
response = client.get('https://google.com')
```

### Configuration

Pigeon comes with configurable options related to http request.

```
options: {
    request_timeout: 60,        # default value
    request_open_timeout: 60,   # default value
    ssl_verify: false,          # default value
}

client = Pigeon::Client.new('http_request', options: options)
response = client.get('https://google.com')
```

Note: `http_request` is a request identifier. It will be used as circuit breaker and datadog monitoring name.

### POST and PUT with Payloads

#### JSON (application/json)
```
require 'pigeon-http'

payload: {
    foo: "bar"
}

client = Pigeon::Client.new('http_request')
response = client.post('https://google.com', body: payload)
```

#### Form URL-encoded (application/x-www-form-urlencoded)
```
require 'pigeon-http'

payload: {
    foo: "bar"
}

client = Pigeon::Client.new('http_request')
response = client.post('https://google.com', query: payload)
```

#### Form Data (multipart/form-data)
```
require 'pigeon-http'

payload: {
    foo: "bar"
}

client = Pigeon::Client.new('http_request')
response = client.post('https://google.com', form: payload)
```

### GET with Query Params

Query params only applicable for GET request.
```
require 'pigeon-http'

param: {
    foo: "bar"
}

client = Pigeon::Client.new('http_request')
response = client.get('https://google.com', query: param)
```

### Retryable

By default, the retry mechanism is disable. We can enable and configure it when initialize the pigeon.


```
options: {
    retryable: false,   # default value
    retry_threshold: 3  # default value
}

client = Pigeon::Client.new('http_request', options: options)
response = client.get('https://google.com')
```

The retry mechanism using backoff time using following calculation:

```
4**n
```

Which `n` is retry counter.