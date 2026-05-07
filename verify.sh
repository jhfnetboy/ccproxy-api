lsof -iTCP:18080 -sTCP:LISTEN -nP  && curl -sf --noproxy '*' http://localhost:18080/health | head -c 100
