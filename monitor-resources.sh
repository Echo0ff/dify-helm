#!/bin/bash
# Dify 生产环境资源监控脚本
# 用于压测时实时监控节点和 Pod 资源使用情况

echo "==================================================================="
echo "🔍 Dify 资源监控 - 实时刷新"
echo "==================================================================="
echo ""

while true; do
    clear
    echo "==================================================================="
    echo "📊 节点资源使用情况 ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "==================================================================="
    kubectl top nodes | awk 'NR==1 {printf "%-30s %10s %15s %10s %15s\n", $1, $2, $3, $4, $5} 
                             NR>1 {
                                 cpu_pct = substr($3, 1, length($3)-1);
                                 mem_pct = substr($5, 1, length($5)-1);
                                 color_cpu = cpu_pct > 80 ? "\033[1;31m" : cpu_pct > 60 ? "\033[1;33m" : "\033[1;32m";
                                 color_mem = mem_pct > 80 ? "\033[1;31m" : mem_pct > 60 ? "\033[1;33m" : "\033[1;32m";
                                 printf "%-30s %10s %s%15s\033[0m %10s %s%15s\033[0m\n", 
                                        $1, $2, color_cpu, $3, $4, color_mem, $5
                             }'
    echo ""
    
    echo "==================================================================="
    echo "🚀 API Pod 资源使用情况 TOP 10"
    echo "==================================================================="
    kubectl top pods -n dify -l component=api --sort-by=memory | head -11 | \
        awk 'NR==1 {printf "%-45s %10s %12s\n", $1, $2, $3} 
             NR>1 {
                 mem_val = substr($3, 1, length($3)-2);
                 color = mem_val > 4096 ? "\033[1;31m" : mem_val > 3072 ? "\033[1;33m" : "\033[1;32m";
                 printf "%-45s %10s %s%12s\033[0m\n", $1, $2, color, $3
             }'
    echo ""
    
    echo "==================================================================="
    echo "👷 Worker Pod 资源使用情况"
    echo "==================================================================="
    kubectl top pods -n dify -l component=worker | \
        awk 'NR==1 {printf "%-45s %10s %12s\n", $1, $2, $3} 
             NR>1 {
                 mem_val = substr($3, 1, length($3)-2);
                 color = mem_val > 2048 ? "\033[1;31m" : mem_val > 1536 ? "\033[1;33m" : "\033[1;32m";
                 printf "%-45s %10s %s%12s\033[0m\n", $1, $2, color, $3
             }'
    echo ""
    
    echo "==================================================================="
    echo "📈 HPA 自动伸缩状态"
    echo "==================================================================="
    kubectl get hpa -n dify -o custom-columns=\
NAME:.metadata.name,\
CURRENT_REPLICAS:.status.currentReplicas,\
DESIRED_REPLICAS:.status.desiredReplicas,\
MIN:.spec.minReplicas,\
MAX:.spec.maxReplicas,\
CPU_TARGET:.spec.targetCPUUtilizationPercentage,\
CPU_CURRENT:.status.currentCPUUtilizationPercentage 2>/dev/null | \
        awk 'NR==1 {printf "%-20s %8s %8s %5s %5s %10s %12s\n", $1, $2, $3, $4, $5, $6, $7}
             NR>1 {
                 diff = $3 - $2;
                 color = diff > 0 ? "\033[1;33m⬆" : diff < 0 ? "\033[1;34m⬇" : "\033[1;32m●";
                 printf "%-20s %8s %s%7s\033[0m %5s %5s %9s%% %11s%%\n", 
                        $1, $2, color, $3, $4, $5, $6, $7
             }'
    echo ""
    
    echo "==================================================================="
    echo "🗺️  Pod 节点分布"
    echo "==================================================================="
    echo "Master 节点 (izbp16g71i3ye4pe52adhmz):"
    kubectl get pods -n dify -o wide | grep "izbp16g71i3ye4pe52adhmz" | grep -E "api|worker" | wc -l | xargs echo "  API+Worker Pod 数量: "
    
    echo "Worker 节点 1 (izbp16qq4fgg0w02hw82owz):"
    kubectl get pods -n dify -o wide | grep "izbp16qq4fgg0w02hw82owz" | grep -E "api|worker" | wc -l | xargs echo "  API+Worker Pod 数量: "
    
    echo "Worker 节点 2 (izbp16qq4fgg0w02hw82oxz):"
    kubectl get pods -n dify -o wide | grep "izbp16qq4fgg0w02hw82oxz" | grep -E "api|worker" | wc -l | xargs echo "  API+Worker Pod 数量: "
    echo ""
    
    echo "==================================================================="
    echo "⚠️  资源告警"
    echo "==================================================================="
    
    # 检查内存使用过高的 Pod
    high_mem_pods=$(kubectl top pods -n dify --no-headers | awk '$3 ~ /Mi$/ {mem=substr($3,1,length($3)-2); if(mem>5120) print $1" "$3}')
    if [ -n "$high_mem_pods" ]; then
        echo "🔴 高内存使用 Pod (>5Gi):"
        echo "$high_mem_pods" | while read line; do echo "  - $line"; done
    else
        echo "✅ 所有 Pod 内存使用正常"
    fi
    
    # 检查节点内存使用
    high_mem_nodes=$(kubectl top nodes --no-headers | awk '{pct=substr($5,1,length($5)-1); if(pct>80) print $1" "$5}')
    if [ -n "$high_mem_nodes" ]; then
        echo "🔴 高内存使用节点 (>80%):"
        echo "$high_mem_nodes" | while read line; do echo "  - $line"; done
    else
        echo "✅ 所有节点内存使用正常"
    fi
    
    echo ""
    echo "🔄 刷新中... (按 Ctrl+C 退出)"
    echo "==================================================================="
    
    sleep 3
done


