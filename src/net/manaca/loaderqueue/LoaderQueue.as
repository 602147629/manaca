/*
 * Copyright (c) 2011, wersling.com All rights reserved.
 */
package net.manaca.loaderqueue
{
import flash.events.EventDispatcher;
import flash.events.TimerEvent;
import flash.utils.Dictionary;
import flash.utils.Timer;

/**
 * 任务队列全部完成后派发
 * @eventType net.manaca.loaderqueue.LoaderQueueEvent.TASK_QUEUE_COMPLETED
 */
[Event(name="taskQueueCompleted", 
    type="net.manaca.loaderqueue.LoaderQueueEvent")]

/**
 * 任务队列及下载队列的管理器
 * @example
 * var urlLoader:URLLoaderAdapter =
 *                           new URLLoaderAdapter(4,"http://ggg.ggg.com/a.swf");
 * urlLoader.addEventListener(LoaderQueueEvent.TASK_COMPLETED,
 *                                                           onLoadedCompleted);
 * urlLoader.container.addEventListener(Event.ENTER_FRAME, onEnterFrame)
 * var loaderQueue:LoaderQueue = new LoaderQueue();
 * loaderQueue.addItem(urlLoader);
 *
 * @see net.manaca.loaderqueue.adapter#URLLoaderAdapter
 *
 * @author sean
 */
public class LoaderQueue extends EventDispatcher implements ILoaderQueue
{
    //==========================================================================
    //  Constructor
    //==========================================================================
    /**
     * Constructs a new <code>Application</code> instance.
     * @param threadLimit 下载线程数的上限
     * @param delay 下载队列排序延迟时间，单位毫秒
     * @param ignoreCache 是否将已经加载过的文件加入到队列中
     */
    public function LoaderQueue(threadLimit:uint = 2, delay:int = 500, 
                                ignoreCache:Boolean = true)
    {
        this.threadLimit = threadLimit;
        this.delay = delay;
        this.ignoreCache = ignoreCache;
        addItemTimer = new Timer(delay, 1);
        addItemTimer.addEventListener(TimerEvent.TIMER_COMPLETE,
                                                    onAddItemTimerCompleted);
    }

    //==========================================================================
    //  Variables
    //==========================================================================
    /**
     * 下载队列排序延迟时间，单位毫秒
     */
    private var delay:int;
    
    private var cacheMap:Object = {};
    //==========================================================================
    //  Properties
    //==========================================================================
    /**
     * 是否将已经加载过的文件加入到队列中
     */    
    public var ignoreCache:Boolean;
    
    /**
     * 最大线程数上限值
     */
    public var threadLimit:uint;

    /**
     * 等级排序时是否使用倒序(如4,3,2,1)
     */
    public var reverseLevel:Boolean = false;

    /**
     * 用于保存所有的下载项目
     * p.s:已下载的会被清除
     * @private
     */
    private var loaderDict:Dictionary/* of ILoaderAdapter */= new Dictionary();

    /**
     * 用于决定下载的等级的顺序
     * @private
     */
    private var loaderLevelLib:Array /* of uint */ = [];

    /**
     * 用于保存目前正在下载的对象
     * @private
     */
    private var threadLib:Array /* of ILoaderAdapter */ = [];

    private var addItemTimer:Timer;

    //==========================================================================
    //  Methods
    //==========================================================================
    public function addItem(loaderAdapter:ILoaderAdapter):void
    {
        loaderAdapter.state = LoaderQueueConst.STATE_WAITING;
        //如果ignoreCache为true,则检查是否已经加载过，如果加载过，则不添加到队列，
        //而是直接开始加载
        if(ignoreCache)
        {
            if(cacheMap[loaderAdapter.url])
            {
                loaderAdapter.start();
                return;
            }
        }
        
        if (loaderDict[loaderAdapter.level] == null)
        {
            loaderDict[loaderAdapter.level] = [];
            loaderLevelLib.push(loaderAdapter.level);
        }
        loaderDict[loaderAdapter.level].push(loaderAdapter);

        loaderAdapter.addEventListener(LoaderQueueEvent.TASK_DISPOSE,
                                       loaderAdapter_disposeHandler);

        // 使用Timer调用是为防止同一时间多个添加造成的性能浪费
        if (!addItemTimer.running)
        {
            addItemTimer.start();
        }
    }

    /**
    * 将LoaderQueue实例中的所有内容消毁，并将下载队列清空
    */
    public function dispose():void
    {
        removeAllItem();
        loaderDict = null;
        loaderLevelLib = null;
        threadLib = null;

        addItemTimer.stop();
        addItemTimer.removeEventListener(TimerEvent.TIMER_COMPLETE,
                                                    onAddItemTimerCompleted);
        addItemTimer = null;
    }

    /**
     * 停止并移除队列中所有等级的下载项
     */
    public function removeAllItem():void
    {
        for each (var i:uint in loaderLevelLib)
        {
            removeItemByLevel(i);
        }
    }

    /**
     * 停止并移除队列中指定的下载项
     * 如想消毁Item实例需手动调用其自身的dispose方法
     */
    public function removeItem(loaderAdapter:ILoaderAdapter):void
    {
        disposeItem(loaderAdapter);
        loaderAdapter.state = LoaderQueueConst.STATE_REMOVED;
    }

    /**
     * 停止并移除队列中所有相应等级的下载项
     * @param level 需停止并移除的等级
     */
    public function removeItemByLevel(level:uint):void
    {
        for each (var i:ILoaderAdapter in loaderDict[level])
        {
            removeItem(i);
        }
    }

    /**
     * 停止并移除队列中除指定等级以外的所有等级的下载项
     * @param level 需保留的等级
     */
    public function saveItemByLevel(level:uint):void
    {
        for each (var i:ILoaderAdapter in loaderDict[level])
        {
            if (i.level != level)
            {
                removeItem(i);
            }
        }
    }

    /**
     * 取得当前正在运行的线程数
     * @return uint
     */
    public function get currentStartedNum():uint
    {
        return threadLib.length;
    }

    /**
     * 检查队列中是否还有项目需下载
     * @private
     */
    private function checkQueueHandle():Boolean
    {
        for each (var level:uint in loaderLevelLib)
        {
            if (loaderDict[level].length > 0)
            {
                return true;
            }
        }
        dispatchEvent(
                new LoaderQueueEvent(LoaderQueueEvent.TASK_QUEUE_COMPLETED));
        return false;
    }

    /**
     * 检查下载线程是否已到最大上限
     * @private
     */
    private function checkThreadHandle(loaderAdapter:ILoaderAdapter):void
    {
        if (loaderAdapter == null)
        {
            //执行到此处说明队列中的所有项目均正在执行
            return;
        }
        if (threadLib.length < threadLimit)
        {
            threadLib.push(loaderAdapter);
            startItem(loaderAdapter);
        }
        else
        {
            threadFullHandle(loaderAdapter);
        }
    }

    /**
     * 将项目从线程池与队列中移出,但并不消毁其自身
     * (如想消毁项目实例需手动调用其自身的dispose方法)
     * p.s:一般在item发生completed与error后调用
     *
     * @private
     */
    private function disposeItem(loaderAdapter:ILoaderAdapter):void
    {
        if (loaderAdapter.isStarted)
        {
            loaderAdapter.removeEventListener(LoaderQueueEvent.TASK_COMPLETED,
                                              loaderAdapter_completedHandler);
            loaderAdapter.removeEventListener(LoaderQueueEvent.TASK_ERROR,
                                              loaderAdapter_errorHandler);
            try
            {
                loaderAdapter.stop();
            }
            catch (e:Error)
            {
                //屏蔽可能的错误
            }
        }
        loaderAdapter.removeEventListener(LoaderQueueEvent.TASK_DISPOSE,
                                          loaderAdapter_disposeHandler);
        var num:uint = threadLib.indexOf(loaderAdapter);
        if (num != -1)
        {
            threadLib.splice(num, 1);
        }
        num = loaderDict[loaderAdapter.level].indexOf(loaderAdapter);

        loaderDict[loaderAdapter.level].splice(num, 1);
    }

    /**
     * 取得下一个需要下载的项目
     * @private
     */
    private function getNextIdleItem():ILoaderAdapter
    {
        for each (var level:uint in loaderLevelLib)
        {
            for each (var loaderAdapter:ILoaderAdapter in loaderDict[level])
            {
                if (!loaderAdapter.isStarted)
                {
                    return loaderAdapter;
                }
            }
        }
        return null;
    }

    /**
     * 启动LoaderAdapter实例
     * @private
     */
    private function startItem(loaderAdapter:ILoaderAdapter):void
    {
        loaderAdapter.state = LoaderQueueConst.STATE_STARTED;
        loaderAdapter.addEventListener(LoaderQueueEvent.TASK_COMPLETED,
                                       loaderAdapter_completedHandler);
        loaderAdapter.addEventListener(LoaderQueueEvent.TASK_ERROR,
                                       loaderAdapter_errorHandler);
        loaderAdapter.start();
    }

    /**
     * 停止LoaderAdapter实例并屏蔽可能引发的错误
     * @private
     */
    private function stopItem(loaderAdapter:ILoaderAdapter):void
    {
        loaderAdapter.state = LoaderQueueConst.STATE_WAITING;
        loaderAdapter.removeEventListener(LoaderQueueEvent.TASK_COMPLETED,
                                          loaderAdapter_completedHandler);
        loaderAdapter.removeEventListener(LoaderQueueEvent.TASK_ERROR,
                                          loaderAdapter_errorHandler);

        try
        {
            loaderAdapter.stop();
        }
        catch (error:Error)
        {
            //屏蔽可能的错误
        }
    }

    /**
     * 当下载线程全部被占用时,对新添加的实例进行的操作
     * @private
     */
    private function threadFullHandle(loaderAdapter:ILoaderAdapter):void
    {
        for (var i:uint = 0; i < threadLib.length; i++)
        {
            var reverseLevelResult:Boolean =
                    checkReverseLevel(threadLib[i].level, loaderAdapter.level);
            if (reverseLevelResult)
            {
                stopItem(threadLib[i]);
                threadLib[i] = loaderAdapter;
                startItem(loaderAdapter);
            }
        }
    }

    /**
     * 将已启动的adapter重新排序
     */
    private function sortStartedItem():void
    {
        var itemLoader:ILoaderAdapter = getNextIdleItem();
        if (itemLoader == null)
        {
            //已无项目，或是所有项目都已开始下载
            //所以已无重新排序必要
            return;
        }
        var oldLevel:int = itemLoader.level;
        var idleLoaderAdapter:ILoaderAdapter;
        var runningLoaderAdapter:ILoaderAdapter;
        for (var i:uint = 0; i < threadLib.length; i++)
        {
            runningLoaderAdapter = threadLib[i];
            var reverseLevelResult:Boolean =
                checkReverseLevel(runningLoaderAdapter.level, oldLevel);
            if (reverseLevelResult)
            {
                idleLoaderAdapter = getNextIdleItem();
                reverseLevelResult =
                                checkReverseLevel(runningLoaderAdapter.level,
                                                    idleLoaderAdapter.level);
                if (reverseLevelResult)
                {
                    stopItem(runningLoaderAdapter);
                    threadLib[i] = idleLoaderAdapter;
                    startItem(idleLoaderAdapter);
                    oldLevel = idleLoaderAdapter.level;
                }
                else
                {
                    oldLevel = runningLoaderAdapter.level;
                }
            }
            else
            {
                oldLevel = runningLoaderAdapter.level;
            }
        }
    }

    /**
     * 如线程池未全部使用，则将等待下载的项目装进线程池
     */
    private function fillThreadPool():void
    {
        var nextIdleAdapter:ILoaderAdapter;
        while (currentStartedNum < threadLimit)
        {
            nextIdleAdapter = getNextIdleItem();
            if (nextIdleAdapter != null)
            {
                threadLib.push(nextIdleAdapter);
                startItem(nextIdleAdapter);
                nextIdleAdapter = null;
            }
            else
            {
                //线程未满，但已没有等待下载的项目时调用此处
                break;
            }
        }
    }

    //==========================================================================
    //  Event Handlers
    //==========================================================================
    private function loaderAdapter_completedHandler(event:LoaderQueueEvent):void
    {
        var loaderAdapter:ILoaderAdapter =
                                          event.currentTarget as ILoaderAdapter;
        if(ignoreCache)
        {
            cacheMap[loaderAdapter.url] = true;
        }
        disposeItem(loaderAdapter);
        
        if (checkQueueHandle())
        {
            checkThreadHandle(getNextIdleItem());
        }
    }

    private function loaderAdapter_errorHandler(event:LoaderQueueEvent):void
    {
        var loaderAdapter:ILoaderAdapter =
                                        event.currentTarget as ILoaderAdapter;
        disposeItem(loaderAdapter);
        if (checkQueueHandle())
        {
            checkThreadHandle(getNextIdleItem());
        }
    }

    /**
    * adataper实例自动调用其自身的dispose方法后触发此处
    * @private
    */
    private function loaderAdapter_disposeHandler(event:LoaderQueueEvent):void
    {
        removeItem(event.target as ILoaderAdapter);
    }

    private function onAddItemTimerCompleted(event:TimerEvent):void
    {
        addItemTimer.reset();

        if (!reverseLevel)
        {
            loaderLevelLib.sort(Array.NUMERIC);
        }
        else
        {
            loaderLevelLib.sort(Array.NUMERIC);
            loaderLevelLib.reverse();
        }

        if (threadLib.length > 0)
        {
            sortStartedItem();
        }
        fillThreadPool();
    }

    /**
     * 根据是否倒序,来得出两个等级之间优先级的结果
     * @param level1
     * @param level2
     * @return
     * @private
     */
    private function checkReverseLevel(level1:uint, level2:uint):Boolean
    {
        if (!this.reverseLevel)
        {
            return level1 > level2;
        }
        return level2 > level1;
    }
}
}