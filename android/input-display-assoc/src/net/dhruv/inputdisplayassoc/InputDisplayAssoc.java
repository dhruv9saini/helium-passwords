package net.dhruv.inputdisplayassoc;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

public final class InputDisplayAssoc {
    private InputDisplayAssoc() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length < 1 || "help".equals(args[0]) || "--help".equals(args[0])) {
            usage();
            return;
        }

        String command = args[0];
        if ("list".equals(command)) {
            listAssociationMethods();
            return;
        }

        if ("add-port".equals(command)) {
            requireArgs(args, 3);
            String inputPort = args[1];
            String displayUniqueId = args[2];
            Integer displayPort = args.length >= 4 ? Integer.valueOf(args[3]) : null;
            if (!addPort(inputPort, displayUniqueId, displayPort)) {
                throw new IllegalStateException("no input/display port association method succeeded");
            }
            return;
        }

        if ("remove-port".equals(command)) {
            requireArgs(args, 2);
            if (!removePort(args[1])) {
                throw new IllegalStateException("no input/display port removal method succeeded");
            }
            return;
        }

        if ("add-descriptor".equals(command)) {
            requireArgs(args, 3);
            if (!invokeAny("addUniqueIdAssociationByDescriptor",
                    new Class<?>[] {String.class, String.class}, args[1], args[2])) {
                throw new IllegalStateException("descriptor association method failed or is unavailable");
            }
            return;
        }

        if ("remove-descriptor".equals(command)) {
            requireArgs(args, 2);
            if (!invokeAny("removeUniqueIdAssociationByDescriptor",
                    new Class<?>[] {String.class}, args[1])) {
                throw new IllegalStateException("descriptor removal method failed or is unavailable");
            }
            return;
        }

        throw new IllegalArgumentException("unknown command: " + command);
    }

    private static void usage() {
        System.out.println("usage:");
        System.out.println("  InputDisplayAssoc list");
        System.out.println("  InputDisplayAssoc add-port INPUT_PORT DISPLAY_UNIQUE_ID [DISPLAY_PORT]");
        System.out.println("  InputDisplayAssoc remove-port INPUT_PORT");
        System.out.println("  InputDisplayAssoc add-descriptor INPUT_DESCRIPTOR DISPLAY_UNIQUE_ID");
        System.out.println("  InputDisplayAssoc remove-descriptor INPUT_DESCRIPTOR");
    }

    private static void requireArgs(String[] args, int count) {
        if (args.length < count) {
            usage();
            throw new IllegalArgumentException("expected at least " + count + " arguments");
        }
    }

    private static boolean addPort(String inputPort, String displayUniqueId, Integer displayPort) {
        boolean ok = false;
        ok |= invokeAny("addUniqueIdAssociationByPort",
                new Class<?>[] {String.class, String.class}, inputPort, displayUniqueId);
        ok |= invokeAny("addUniqueIdAssociation",
                new Class<?>[] {String.class, String.class}, inputPort, displayUniqueId);
        if (displayPort != null) {
            ok |= invokeAny("addPortAssociation",
                    new Class<?>[] {String.class, int.class}, inputPort, displayPort.intValue());
        }
        return ok;
    }

    private static boolean removePort(String inputPort) {
        boolean ok = false;
        ok |= invokeAny("removeUniqueIdAssociationByPort",
                new Class<?>[] {String.class}, inputPort);
        ok |= invokeAny("removeUniqueIdAssociation",
                new Class<?>[] {String.class}, inputPort);
        ok |= invokeAny("removePortAssociation",
                new Class<?>[] {String.class}, inputPort);
        return ok;
    }

    private static boolean invokeAny(String methodName, Class<?>[] types, Object... args) {
        boolean ok = false;
        for (Object target : targets()) {
            if (target == null) {
                continue;
            }
            try {
                Method method = target.getClass().getMethod(methodName, types);
                method.setAccessible(true);
                method.invoke(target, args);
                System.out.println(methodName + " ok via " + target.getClass().getName());
                ok = true;
            } catch (NoSuchMethodException ignored) {
                // Try the next target; Android has moved these methods between releases.
            } catch (Throwable ex) {
                Throwable cause = ex.getCause() == null ? ex : ex.getCause();
                System.out.println(methodName + " failed via " + target.getClass().getName()
                        + ": " + cause.getClass().getName() + ": " + cause.getMessage());
            }
        }
        return ok;
    }

    private static List<Object> targets() {
        ArrayList<Object> out = new ArrayList<>();
        out.add(staticInstance("android.hardware.input.InputManager", "getInstance"));
        out.add(staticInstance("android.hardware.input.InputManagerGlobal", "getInstance"));
        out.add(inputService());
        return out;
    }

    private static Object staticInstance(String className, String methodName) {
        try {
            Class<?> cls = Class.forName(className);
            Method method = cls.getDeclaredMethod(methodName);
            method.setAccessible(true);
            return method.invoke(null);
        } catch (Throwable ex) {
            return null;
        }
    }

    private static Object inputService() {
        try {
            Class<?> serviceManager = Class.forName("android.os.ServiceManager");
            Method getService = serviceManager.getDeclaredMethod("getService", String.class);
            Object binder = getService.invoke(null, "input");
            Class<?> stub = Class.forName("android.hardware.input.IInputManager$Stub");
            Method asInterface = stub.getDeclaredMethod(
                    "asInterface", Class.forName("android.os.IBinder"));
            return asInterface.invoke(null, binder);
        } catch (Throwable ex) {
            return null;
        }
    }

    private static void listAssociationMethods() {
        for (Object target : targets()) {
            if (target == null) {
                continue;
            }
            System.out.println("target " + target.getClass().getName());
            for (Method method : target.getClass().getMethods()) {
                if (method.getName().contains("Association")) {
                    System.out.println("  " + method.toString());
                }
            }
        }
    }
}
