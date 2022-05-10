module serverino.tests.common;

version(unittest):

public import serverino;
public import serverino.daemon;
public import serverino.worker;

template ServerinoTest(Modules...)
{
    import core.thread;
    mixin ServerinoLoop!Modules;

    Thread background;

    void runOnBackgroundThread() {background = new Thread({mainServerinoLoop((string[]).init);}).start();}

    void terminateBackgroundThread()
    {
        Daemon.instance.shutdown();
        background.join(true);
    }
}