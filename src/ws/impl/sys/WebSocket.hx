package ws.impl.sys;

import haxe.MainLoop;
import sys.thread.Thread;
import ws.impl.Types.BinaryType;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.Error;
import sys.ssl.Socket as SecureSocket;

@:noCompletion
class WebSocket extends WebSocketBase {
	public var _protocol:String;
	public var _host:String;
	public var _port:Int = 0;
	public var _path:String;

	private var _processThread:Thread;
	private var _encodedKey:String = "wskey";

	public var binaryType:BinaryType;
	public var manualProcess:Bool = false;

	public var additionalHeaders(get, null):Map<String, String>;

	public var rawSocket(get, never):Socket;

	inline function get_rawSocket():Socket {
		return _socket;
	}

	public function new(url:String, immediateOpen = true) {
		parseUrl(url);

		super(createSocket());

		if (immediateOpen) {
			open();
		}
	}

	inline private function parseUrl(url) {
		var urlRegExp = ~/^(\w+?):\/\/([\w\.-]+)(:(\d+))?(\/.*)?$/;

		if (!urlRegExp.match(url)) {
			throw 'Uri not matching websocket URL "${url}"';
		}

		_protocol = urlRegExp.matched(1);

		_host = urlRegExp.matched(2);

		var parsedPort = Std.parseInt(urlRegExp.matched(4));
		if (parsedPort > 0) {
			_port = parsedPort;
		}
		_path = urlRegExp.matched(5);
		if (_path == null || _path.length == 0) {
			_path = "/";
		}
	}

	private function createSocket():Socket {
		if (_protocol == "wss") {
			/*
				#if (java || cs)
					throw "Secure sockets not implemented";
				#else
			 */
			if (_port == 0) {
				_port = 443;
			}
			return new SecureSocket();

			// throw "todo wss";
		} else if (_protocol == "ws") {
			if (_port == 0) {
				_port = 80;
			}
			return new Socket();
		} else {
			throw 'Unknown protocol $_protocol';
		}
	}

	public function open() {
		if (state != State.Handshake) {
			throw "Socket already connected";
		}
		_socket.setBlocking(true);
		_socket.connect(new sys.net.Host(_host), _port);
		_socket.setBlocking(false);

		if (!manualProcess) {
			#if !cs
			#if websockets_threaded
			_processThread = Thread.create(processThread);
			_processThread.sendMessage(this);
			#else
			var event:haxe.MainLoop.MainEvent = null;
			event = haxe.MainLoop.add(() -> {
				if (this.state != State.Closed) { // TODO: should think about mutex
					this.process();
				} else {
					event.stop();
				}
			});
			#end
			#else
			#if websockets_threaded
			haxe.MainLoop.addThread(function() {
				processLoop(this);
			});
			#else
			var event:haxe.MainLoop.MainEvent = null;
			event = haxe.MainLoop.add(() -> {
				if (this.state != State.Closed) { // TODO: should think about mutex
					this.process();
				} else {
					event.stop();
				}
			});
			#end
			#end
		}

		sendHandshake();
	}

	public function processReady() {
		if (_onopenCalled == false) {
			_onopenCalled = true;
			if (onopen != null) {
				onopen();
			}
		}

		if (_lastError != null) {
			var error = _lastError;
			_lastError = null;
			if (onerror != null) {
				onerror(error);
			}
		}

		var needClose = false;
		var data = Bytes.alloc(ws.Defines.bufferSize());
		try {
			var read = _socket.input.readBytes(data, 0, data.length);
			if (read > 0) {
				_buffer.writeBytes(data.sub(0, read));
			}
		} catch (e:Dynamic) {
			needClose = !isBlockedError(e);
		}

		if (!needClose) {
			handleData();
			// After handshake processing, _onopenCalled transitions from null to false.
			// Fire onopen immediately so isConnected is set and heartbeats can start.
			if (_onopenCalled == false) {
				_onopenCalled = true;
				if (onopen != null) {
					onopen();
				}
			}
		} else {
			if (state != State.Closed) {
				try {
					state = State.Closed;
					_socket.close();
				} catch (e:Dynamic) {}
				if (onclose != null) {
					onclose();
				}
			}
		}
	}

	private static function isBlockedError(e:Dynamic):Bool {
		if (Std.isOfType(e, String)) {
			var s:String = cast e;
			var lower = s.toLowerCase();
			return lower == 'blocked' || lower == 'blocking';
		}
		if (Std.isOfType(e, Error)) {
			return (e : Error).match(Error.Blocked);
		}
		if (Std.isOfType(e, haxe.Exception)) {
			var msg = (e : haxe.Exception).message.toLowerCase();
			return msg == 'blocked' || msg == 'blocking';
		}
		return false;
	}

	private function processThread() {
		var ws:WebSocket = Thread.readMessage(true);
		processLoop(this);
	}

	private function processLoop(ws:WebSocket) {
		while (ws.state != State.Closed) {
			ws.process();
			// Sys.sleep(0.1);						//
		}
	}

	function get_additionalHeaders() {
		if (additionalHeaders == null) {
			additionalHeaders = new Map<String, String>();
		}
		return additionalHeaders;
	}

	public function sendHandshake() {
		var httpRequest = new HttpRequest();
		httpRequest.method = "GET";
		// TODO: should propably be hostname+port+path?
		httpRequest.uri = _path;
		httpRequest.httpVersion = "HTTP/1.1";

		httpRequest.headers.set(HttpHeader.HOST, _host + ":" + _port);
		httpRequest.headers.set(HttpHeader.USER_AGENT, "haxeui-core/websockets");
		httpRequest.headers.set(HttpHeader.SEC_WEBSOSCKET_VERSION, "13");
		httpRequest.headers.set(HttpHeader.UPGRADE, "websocket");
		httpRequest.headers.set(HttpHeader.CONNECTION, "Upgrade");
		httpRequest.headers.set(HttpHeader.PRAGMA, "no-cache");
		httpRequest.headers.set(HttpHeader.CACHE_CONTROL, "no-cache");
		httpRequest.headers.set(HttpHeader.ORIGIN, _socket.host().host.toString() + ":" + _socket.host().port);

		_encodedKey = generateWSKey();
		httpRequest.headers.set(HttpHeader.SEC_WEBSOCKET_KEY, _encodedKey);

		if (additionalHeaders != null) {
			for (k in additionalHeaders.keys()) {
				httpRequest.headers.set(k, additionalHeaders[k]);
			}
		}

		sendHttpRequest(httpRequest);
	}

	private override function handleData() {
		switch (state) {
			case State.Handshake:
				var httpResponse = recvHttpResponse();
				if (httpResponse == null) {
					return;
				}

				handshake(httpResponse);
				handleData();
			case _:
				super.handleData();
		}
	}

	private function handshake(httpResponse:HttpResponse) {
		if (httpResponse.code != 101) {
			if (onerror != null) {
				onerror(httpResponse.headers.get(HttpHeader.X_WEBSOCKET_REJECT_REASON));
			}
			close();
			return;
		}

		var secKey = httpResponse.headers.get(HttpHeader.SEC_WEBSOSCKET_ACCEPT);

		if (secKey == null) {
			trace("This server does not implement Sec-WebSocket-Key.");
		} else {
			if (secKey != makeWSKeyResponse(_encodedKey)) {
				if (onerror != null) {
					onerror("Error during WebSocket handshake: Incorrect 'Sec-WebSocket-Accept' header value");
				}
				close();
				return;
			}
		}

		_onopenCalled = false;
		state = State.Head;
	}

	private function generateWSKey():String {
		var b = Bytes.alloc(16);
		for (i in 0...16) {
			b.set(i, Std.random(255));
		}
		return Base64.encode(b);
	}
}
