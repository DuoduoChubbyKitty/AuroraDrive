//
//  burn.cpp —— 受控背景负载生成器
//
//  用途：模拟「游戏 + 后台进程抢核」的优先级分布，供 AD_FLOW_THREADS 扫描使用。
//  按 Vendor/OpenCVFlow/flow_bridge.cpp 头注释的既有方法论：
//  背景负载跑在 **UTILITY** QoS（模拟游戏/后台的真实优先级分布），
//  被测的光流跑在 **USER_INTERACTIVE**（与生产 tick 一致）。
//
//  用法: ./burn <线程数> <持续秒数>
//

#include <pthread.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

int main(int argc, char **argv) {
    const int nThreads = argc > 1 ? std::atoi(argv[1]) : 6;
    const int seconds  = argc > 2 ? std::atoi(argv[2]) : 30;

    std::atomic<bool> stop{false};
    std::vector<std::thread> pool;
    pool.reserve(static_cast<size_t>(nThreads));

    for (int i = 0; i < nThreads; ++i) {
        pool.emplace_back([&stop] {
            // 关键：背景负载用 UTILITY，与生产里游戏/后台进程的优先级分布一致
            pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
            volatile double x = 1.0;
            while (!stop.load(std::memory_order_relaxed)) {
                for (int k = 0; k < 200000; ++k) {
                    x = x * 1.0000001 + 0.0000001;
                }
            }
        });
    }

    std::printf("[burn] %d 线程 @ UTILITY，持续 %d 秒\n", nThreads, seconds);
    std::fflush(stdout);
    std::this_thread::sleep_for(std::chrono::seconds(seconds));
    stop.store(true);
    for (auto &t : pool) t.join();
    return 0;
}
