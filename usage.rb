require 'influxdb'
require 'json'
require 'date'

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

# Get cluster cost information
money_data = get_report(CLOUDHEALTH_REPORT.to_s) #The custom k8s report
cluster_cost = money_data['data'][money_data['data'].size-2].first[0] #Total cost for 2 days ago

# Point to our metric db
database = 'k8s_usage'
influxdb = InfluxDB::Client.new database,
                                username: INFLUXDB_USERNAME,
                                password: INFLUXDB_PASSWORD,
                                host: INFLUXDB_HOST,
                                retry: 5

# Look at the data for the last 20 minutes, exactly 2 days ago
start_date = (DateTime.now - 2)
end_date = start_date+ Rational(20, 1440)

namespace_totals = {}
total_cores = 0
influxdb.query "select * from \"pod_cpu\" where time > '#{start_date.strftime('%Y-%m-%d %T')}'
                  and time < '#{end_date.strftime('%Y-%m-%d %T')}' group by namespace" do |_, b, c|
                    namespace = b['namespace']
                    namespace_data = c
                    total = 0
                    pods = 0
                    namespace_data.each do |d|
                      total += d['max_cpu']
                    end
                    namespace_totals[namespace] = total
                    total_cores += total
                  end

data = []
namespace_totals.each do |k,v|
  data.push(
    {
      series: 'namespace_metrics',
      timestamp: start_date.to_time.to_i,
      tags: { namespace: k },
      values: { cpu_percent: (v / total_cores.to_f) * 100, daily_cost: (v / total_cores.to_f) * cluster_cost }
    })
end

influxdb.write_points(data)
influxdb.write_points(pod_data)
puts data
puts "Finished run at #{Time.now}"
