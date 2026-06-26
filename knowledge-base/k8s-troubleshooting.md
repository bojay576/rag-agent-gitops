# Kubernetes Troubleshooting Guide

## Pod Pending

If a Pod is stuck in `Pending` state:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Common causes:
- **Insufficient resources**: Node doesn't have enough CPU/memory. Check with `kubectl top nodes`.
- **Unbound PVC**: PersistentVolumeClaim cannot bind to a PV. Check with `kubectl get pvc -n <namespace>`.
- **NodeSelector/Affinity**: No node matches the pod's scheduling constraints.
- **Taints/Tolerations**: The pod doesn't tolerate the node's taints.

Solutions:
- Add more nodes or reduce resource requests.
- Create a matching PV or install a StorageClass provisioner.
- Review and adjust nodeSelector, affinity, or tolerations.

## Pod CrashLoopBackOff

When a pod keeps crashing after starting:

```bash
kubectl logs <pod-name> -n <namespace> --previous
kubectl describe pod <pod-name> -n <namespace>
```

Common causes:
- **Application error**: Check the logs for stack traces or panic messages.
- **OOMKilled**: Memory limit exceeded. Check `kubectl describe pod` for "OOMKilled" in exit reason.
- **Missing ConfigMap/Secret**: The pod references a non-existent ConfigMap or Secret.
- **Wrong command/args**: The container entrypoint exits immediately.

Solutions:
- Fix the application bug.
- Increase memory limits in the deployment spec.
- Create the missing ConfigMap or Secret.
- Check `command` and `args` in the container spec.

## Image Pull Errors

### ImagePullBackOff

```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep -i pull
```

Common causes:
- **Wrong image tag**: The specified image:tag doesn't exist in the registry.
- **Authentication failure**: Private registry requires `imagePullSecrets`.
- **Network issue**: The node cannot reach the container registry.
- **Rate limiting**: Docker Hub has pull rate limits for anonymous users.

Solutions:
- Verify the image name and tag: `docker pull <image>:<tag>` on a local machine.
- Create a Docker registry secret: `kubectl create secret docker-registry regcred --docker-server=<registry> --docker-username=<user> --docker-password=<password> --docker-email=<email>`
- Add `imagePullSecrets` to the pod spec.
- Use a mirror registry or configure `registry-mirrors` in the container runtime.

## Service Connectivity

### Can't reach a Service

```bash
# Check if endpoints exist
kubectl get endpoints <service-name> -n <namespace>

# Test from a debug pod
kubectl run debug --rm -it --image=nicolaka/netshoot -- /bin/bash
# Inside: curl http://<service-name>.<namespace>.svc.cluster.local:<port>
```

Common causes:
- **No endpoints**: The service selector doesn't match any pod labels.
- **Wrong port**: The service port or targetPort doesn't match the container port.
- **NetworkPolicy**: A NetworkPolicy is blocking the traffic.
- **Pod not ready**: The pod is running but failing readinessProbe.

Solutions:
- Verify labels match between service selector and pod labels.
- Check `kubectl get endpoints` — if empty, labels don't match.
- Review NetworkPolicy rules in the namespace.
- Check readinessProbe configuration.

## Storage Issues

### PVC Stuck in Pending

```bash
kubectl get pvc -n <namespace>
kubectl describe pvc <pvc-name> -n <namespace>
```

Common causes:
- **No StorageClass**: Dynamic provisioning requires a default StorageClass.
- **No matching PV**: For static binding, no PV matches the PVC's size and access mode.
- **StorageClass not found**: The PVC references a non-existent StorageClass.

Solutions:
- Install a StorageClass provisioner (e.g., `local-path-provisioner`).
- Create a PV with matching capacity and access mode.
- Fix the `storageClassName` in the PVC spec.

## Useful Debugging Commands

```bash
# Get all events in a namespace, sorted by time
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Show resource usage
kubectl top pods -n <namespace>
kubectl top nodes

# Run a shell in a running container
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Copy files to/from a pod
kubectl cp <pod-name>:/path/to/file ./local-file -n <namespace>

# Port-forward to a pod or service
kubectl port-forward svc/<service-name> 8080:80 -n <namespace>
```
