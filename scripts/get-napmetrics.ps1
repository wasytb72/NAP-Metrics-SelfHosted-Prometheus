$url='http://localhost:9090'
curl.exe -s  $url/api/v1/label/__name__/values | jq -r ".data[]" | select-string nap_ |sort-object