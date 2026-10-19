hostname -I | awk '{print $1}'
mkdir -p ~/Webserver
cd ~/Webserver
python3 -m http.server 8080

