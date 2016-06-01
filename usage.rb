require 'influxdb'
require 'json'

puts "Starting run at #{Time.now}"
database = 'k8s'
limits = {}
usage = {}
pod_data = []
total_cores = 0
API_ENDPOINT = 'https://chapi.cloudhealthtech.com/olap_reports/custom/'.freeze
API_KEY = ENV['CLOUDHEALTH_KEY']
CLOUDHEALTH_REPORT = ENV['CLOUDHEALTH_REPORT']
INFLUXDB_USERNAME = ENV['INFLUXDB_USERNAME']
INFLUXDB_PASSWORD = ENV['INFLUXDB_PASSWORD']
INFLUXDB_HOST = ENV['INFLUXDB_HOST']
influxdb = InfluxDB::Client.new database,
                                username: INFLUXDB_USERNAME,
                                password: INFLUXDB_PASSWORD,
                                host: INFLUXDB_HOST,
                                retry: 5

# Returns json for requested report.
def get_report(report)
  uri = URI(API_ENDPOINT) + report + "?api_key=#{API_KEY}"
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  request['Accept'] = 'application/json'
  response = http.request(request)
  raise "Server returned error #{response.code} processing your API request" if response.code != "200"
  JSON.parse(response.body)
end
# Get all pods, put each into hashmap with their cpu limit
influxdb.query 'SELECT value,pod_namespace FROM "cpu/limit" WHERE time > now() - 30s
                  AND type = \'pod\' GROUP BY pod_name' do |a, b, c|
                    limits[b['pod_name']] = [c[0]['value'],c[0]['pod_namespace']]
                  end

# Get all pods, put each into hashmap with their cpu usage
influxdb.query 'SELECT value,pod_namespace FROM "cpu/usage_rate" WHERE time > now() - 30s
                  AND type = \'pod\' GROUP BY pod_name' do |a, b, c|
                      usage[b['pod_name']] = c[0]['value']
                  end

# Get all cpu request for each pod. If the request is > limit, update hashmap
influxdb.query 'SELECT value,pod_namespace FROM "cpu/request" WHERE time > now() - 30s
                  AND type = \'pod\' GROUP BY pod_name' do |_, b, c|
                    unless limits[b['pod_name']].nil?
                      max = [limits[b['pod_name']].first, usage.fetch(b['pod_name'],0), c[0]['value']].max
                      pod_data.push(
                        {
                          series: 'pod_cpu',
                          tags: { name: b['pod_name'], namespace: c[0]['pod_namespace'] },
                          values: { max_cpu: max, cpu_limit: limits[b['pod_name']][0], cpu_request: c[0]['value'], cpu_usage: usage.fetch(b['pod_name'],0) }
                        })
                      limits[b['pod_name']] = [ max, c[0]['pod_namespace']]
                    end
                  end

# Tally up resources used by each namespace
namespace_totals = {}
limits.each do |k,v|
  if namespace_totals[v[1]].nil?
    namespace_totals[v[1]] = v[0]
  else
    namespace_totals[v[1]] = v[0] + namespace_totals[v[1]]
  end
end

# Get cluster cost information
money_data = get_report(CLOUDHEALTH_REPORT.to_s) #The custom k8s report
cluster_cost = money_data['data'].last.first[0].to_f # This is the total amount the cluster costed yesterday

# Find total number of cores
namespace_totals.each do |k, v|
  total_cores += v
end

#Write Out the metrics
database = 'k8s_usage'
influxdb = InfluxDB::Client.new database,
                                username: INFLUXDB_USERNAME,
                                password: INFLUXDB_PASSWORD,
                                host: INFLUXDB_HOST,
                                retry: 5
data = []
namespace_totals.each do |k,v|
  data.push(
    {
      series: 'namespace_metrics',
      tags: { namespace: k },
      values: { cpu_percent: (v / total_cores.to_f) * 100, daily_cost: (v / total_cores.to_f) * cluster_cost }
    })
end

influxdb.write_points(data)
influxdb.write_points(pod_data)
puts "Finished run at #{Time.now}"
