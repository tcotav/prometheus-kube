## Kubernetes -> Prometheus + Alertmanager + Grafana Dashboard

This project contains a working starter kubernetes monitoring solution using prometheus.  There's probably other ways to do it with prometheus, but hopefully this gives you a good start or a sample to build off of.

### Prelude

This written under the assumption that you've got your own kubernetes cluster running in Google cloud.  I also assume that you've got [node_exporter](https://github.com/prometheus/node_exporter) running on all your nodes.  Here's a [sample node_exporter systemd service file](nodexporter.service).  At the very least you can pull the `docker run` from it and use it in whatever OS you're using.

What I suggest doing is get this all working first end to end before you go beyond minimal config changes (i.e. start doing crazy customizations).  Here is what you should have at the end:

  - prometheus scraping node and kubernetes data
  - node_exporter on all nodes
  - alertmanager sending alerts to hipchat and email
  - grafana with kubernetes dashboards driven by prometheus data

### Pre-flight -- Check all the configs, make them your own

In the `cluster` subdir, you'll see 3 config files and a bash script to create a kubernetes [configmap](http://kubernetes.io/docs/user-guide/configmap/) in the cluster.  We want to change these to match our own environments.

#### kube.rules

This is a collection of [rules for alerting](https://prometheus.io/docs/alerting/rules/) that we'll load into prometheus.  This should be ok as-is to start with.  As you learn your environment more you can add, subtract, and modify this file.

#### am-simple.yml

This is the configuration file for the alertmanager service.  You'll want to set the smtp configs in the `global:` section and update the hipchat url if your organization has one different from the default.  I'm using `sendgrid` here, but change that to whatever smtp server you've got set up.

Next hop down to the `receivers:` section and again set the email and hipchat settings to match your environment.  Note which token you want to retrieve to get access to the hipchat room specified (I only mention here because I biff this one a lot).

#### prometheus.yml

I blatantly stole this off the internet.  It works...  though the TLS stuff may barf depending on how you're set up.  Just leave it for now :).  If it doesn't work, there's [some notes in the prometheus source that describe things more](https://github.com/prometheus/prometheus/blob/master/documentation/examples/prometheus-kubernetes.yml).


#### promtool -- or did I just break some stuff when changing those configs?

This is an optional step but not really.  You'll want to check your changed configs before you unleash them out on the world.  First download the binary as part of the [prometheus binary download](https://prometheus.io/download/).  Drop `promtool` into the directory with your prometheus.yml, rules, etc.

First test your prometheus config with:

```
$ ./promtool check-config prometheus.yml
```

This might cause some errors because its not running in your container.  For example, you can ignore the following:

```
Checking prometheus.yml
  FAILED: error checking bearer token file "/var/run/secrets/kubernetes.io/serviceaccount/token": stat /var/run/secrets/kubernetes.io/serviceaccount/token: no such file or directory
```


Next lets take a crack at the alerting rules:

```
./promtool check-rules kube.rules
```

Ok, assuming you've fixed any problems you've found (out of scope for this doc) now you're ready to move on.


### Persistent Volumes

Be sure you know [what you're getting into here first](http://kubernetes.io/docs/user-guide/persistent-volumes/).

Pre-create the persistent volumes for prometheus and grafana.  If you don't care about the data, then you'll have to modify the yaml later.  **What that'll mean to you is that should you kill all the prometheus pods, you'll lose that data.**  Also, I assume that you're in `us-central1-a` zone for GCE -- change as applicable.

```
gcloud compute disks create --size=4GB --zone=us-central1-a prom-cluster-volume
gcloud compute disks create --size=1GB --zone=us-central1-a graf-prom-cluster-vol
```

### Create the configmaps containing your configurations

I wrote a bash script that will do the following:

  - check if a configmap of the same name already exists (should each configmap have a distinct name or version?)
  - if it exists, delete it
  - create a configmap using the files that we tweaked above in part one
  - test if alertmanager and prometheus are already running
  - if so, kill their pods if they are running so the replication controller will create a new one and pick up the config.  (not sure of a better way to do this as of k8s 1.3)

You can confirm that you've got a configmap in your current namespace by running:

```
kubectl get configmaps 
```

You should see it there along with the `AGE` column which should be pretty fresh and new.


### Bring it all up!!!

First up we'll bring up the services for all three of the replication controllers:

```
kubectl create -f prom-svc.yaml
kubectl create -f graf-svc.yaml
kubectl create -f am-svc.yaml
```

These will appear in your list of running services:

```
kubectl get svc
```

will give you the following header and some data:

```
NAME                      CLUSTER-IP      EXTERNAL-IP      PORT(S)    AGE
```

Initially, `EXTERNAL-IP` might be empty.  Google cloud is busy in the background getting an IP and setting up a firewall rule for your new service.  Here's the good news -- it'll be fully accessible once you get some pods running behind the service.  *Here's the bad news -- it'll be open to the entire internet.*  So take a moment now to log into the google console to update these firewall rules to be locked down a bit.  Or not.  

From the command line, you can (maybe) use the google cloud cli to update as well.  Get the list of firewall rules created automatically by kubernetes:

```
$ gcloud compute firewall-rules list | grep 'k8s-fw-'
```

Find the entries matching the prometheus and alertmanager ports (default for those are `tcp:9090` for prometheus and `tcp:9093`

```
$ gcloud compute firewall-rules list | grep 'k8s-fw-' | grep 'tcp:9090\|tcp:9093'
```

If you're lucky, there are only two entries and you can go ahead with your plan.  If not, then you have to use the website and match your container name with the description field of the rule.

Now we [update](https://cloud.google.com/sdk/gcloud/reference/compute/firewall-rules/update) to whatever matches your environment:

```
$ gcloud compute firewall-rules update k8s-fw-00000000000000000000000000000000 --source-ranges 8.8.8.8
```

Ok, once we've got that locked down, we're ready to spin up our deployments.

#### Deploy Alertmanager

This one should be easy-peasy.  The troubleshooting will come later when you can or cannot get mail or hipchat messages or whatever else you pushed in here. 

```
kubectl create -f am-deploy.yaml
```

Confirm its running:

```
kubectl get pods | grep "^am-cluster-"
```

and hopefully that looks like this:

```
am-cluster-46814560-271kv             1/1       Running   0          1d
```

If it has `STATUS` of `Running`, then you can try out the GUI for it.  Get the IP from the third column here:

```
kubectl get svc | grep '^am-cluster'
```

and then try it out in a browser:

```
http://<ip-of-am-service>:9093
```

Hopefully you can do a happy dance.  Maybe you can't.  To see what went wrong (probably a config error), find the pod name and then check the logs for that pod.  We may have to come back to this one after we start firing off alerts.

```
kubectl get pods | grep "^am-cluster-"
```

then copy that name -- we'll use the example name of `am-cluster-46814560-271kv`

```
kubectl logs -f am-cluster-46814560-271kv 
```

and work out the troubleshooting there.  Most likely we'll be back as we try to send mail and hipchat messages :)  For now though -- forward!


#### Deploy Prometheus

Do the same for Prometheus:

```
kubectl create -f prom-deploy.yaml
```

Confirm its running:

```
kubectl get pods | grep "^prom-cluster-"
```

and hopefully that looks like this:

```
prom-cluster-46814560-271kv             1/1       Running   0          1d
```

If it has `STATUS` of `Running`, then you can try out the GUI for it.  Get the IP from the third column here:

```
kubectl get svc | grep '^prom-cluster'
```

and then try it out in a browser:

```
http://<yourip>:9090
```

Check the `Alerts` tab and you should see the alerts you created in `kube.rules`.

Same as before, check the logs if things didn't work out.

```
kubectl get pods | grep "^prom-cluster-"
```

then copy that name -- we'll use the example name of `prom-cluster-46814560-271kv`

```
kubectl logs -f prom-cluster-46814560-271kv 
```

This one most likely will be a config problem or perhaps problems communicating with kubernetes.  Get this working before moving on else you'll be sad and bored.

#### Deploy Grafana

This should be the easiest. 

```
kubectl create -f grafana-deploy.yaml
```

Then we'll connect and do the rest of our work from inside the grafana GUI.  Get that ip same as before:

```
kubectl get svc | grep '^graf-prom-cluster'
```

Third column and then pop it into your browser.  We run this on port 80 so no need to add the 3000 (unless you modified the service yaml of course).

```
http://<ip-of-grafana-service>
```

#### Configure Prometheus as a datasource in Grafana

First step here is to create a Prometheus datasource.  Use the menu on the left side of the screen to get to the create datasource option.  

Get the IP of the Prometheus service one more time:

```
kubectl get svc | grep '^prom-cluster'
```

as <ip-of-prom-cluster>

Put in the following settings:
```
Name: promcluster
Type: Prometheus
Url: http://<ip-of-prom-cluster>:9090
Access: Direct

Basic Auth -- unchecked
With Credentials -- unchecked
```

The name is important as we're going to be importing some json files to magically create dashboards here in a moment.

Click `Save & Test` to confirm your stuff.

#### Import the pre-created dashboards

Back to the menu in the upper left, click

```
-> Dashboards -> Import
```

bringing up the `Import file` page.  `Choose file` and navigate to this repo/dashboards and select the file 'cluster-dashboard.json'.  

**Note: this is a dashboard created by Ryan vanniekird and available [here](https://grafana.net/dashboards/162).**

This should automagically work.  If not, there's probably some disconnect between your datasource name and what's expected by the dashboard.

Do the same with the file `Kubernetes_internals.json` which is no where near as cool and is really a work in progress.


### Testing alerts

This was a pain.  What I did was duplicated a rule in the file `kube.rule`, changed the name so I'd know it was a test, and then set the alert threshold so low that it was guaranteed to fire.  You can do this by changing the `kube.rule` file and then re-running the `configmap-prom.sh` script.

## TODO

  - document how to lock down each component properly on the internet
  - expand on the kubernetes internals dashboard (after first figuring out wth some of those metrics mean)
  - more troubleshooting notes, tips, tricks



Feel free to contact me -- I'm not an expert at any of this by any means though :).  Pull requests welcome.


  

