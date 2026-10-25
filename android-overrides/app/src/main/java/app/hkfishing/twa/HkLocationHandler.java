/*
 * Based on com.google.androidbrowserhelper.locationdelegation (android-browser-helper,
 * Copyright Google LLC, Apache License 2.0). Modified for 釣港:
 *  - A transient LocationAvailability=false from FusedLocationProvider no longer aborts the
 *    request (upstream LocationProviderGmsCore stops updates and reports "Location not
 *    available.", which Chrome turns into POSITION_UNAVAILABLE / code 2 right away).
 *    We only report an error when system location is really switched off; otherwise we keep
 *    listening and let the web page's own `timeout` decide.
 *  - Falls back to android.location.LocationManager when Google Play services is missing.
 */
package app.hkfishing.twa;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.browser.trusted.TrustedWebActivityCallbackRemote;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.location.FusedLocationProviderClient;
import com.google.android.gms.location.LocationAvailability;
import com.google.android.gms.location.LocationCallback;
import com.google.android.gms.location.LocationRequest;
import com.google.android.gms.location.LocationResult;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.location.Priority;
import com.google.androidbrowserhelper.locationdelegation.PermissionRequestActivity;
import com.google.androidbrowserhelper.trusted.ExtraCommandHandler;

public class HkLocationHandler implements ExtraCommandHandler {
    private static final String TAG = "HK_TwaLocation";
    // Command / callback names must match Chrome + android-browser-helper.
    private static final String CMD_CHECK_PERMISSION = "checkAndroidLocationPermission";
    private static final String CMD_START = "startLocation";
    private static final String CMD_STOP = "stopLocation";
    private static final String CB_LOCATION = "onNewLocationAvailable";
    private static final String CB_ERROR = "onNewErrorAvailable";

    @Nullable private TrustedWebActivityCallbackRemote mCallback;
    @Nullable private FusedLocationProviderClient mFused;
    @Nullable private LocationManager mLm;
    private boolean mRunning;
    private Context mContext;

    private final LocationCallback mFusedCallback = new LocationCallback() {
        @Override public void onLocationResult(@NonNull LocationResult r) { send(r.getLastLocation()); }
        @Override public void onLocationAvailability(@NonNull LocationAvailability a) {
            // Upstream aborts here. Availability=false is common for a few seconds after a cold
            // start or indoors, so only fail if location is switched off at system level.
            if (!a.isLocationAvailable() && !systemLocationEnabled()) {
                stop();
                error("Location services are turned off.");
            } else if (!a.isLocationAvailable()) {
                Log.d(TAG, "Location temporarily unavailable; still waiting for a fix.");
            }
        }
    };

    private final LocationListener mAndroidListener = new LocationListener() {
        @Override public void onLocationChanged(@NonNull Location l) { send(l); }
        @Override public void onStatusChanged(String p, int s, Bundle e) {}
        @Override public void onProviderEnabled(@NonNull String p) {}
        @Override public void onProviderDisabled(@NonNull String p) {}
    };

    @NonNull @Override
    public Bundle handleExtraCommand(Context context, String commandName, Bundle args,
                                     @Nullable TrustedWebActivityCallbackRemote callback) {
        mContext = context.getApplicationContext();
        Bundle result = new Bundle();
        result.putBoolean(EXTRA_COMMAND_SUCCESS, false);
        switch (commandName) {
            case CMD_CHECK_PERMISSION:
                if (callback == null) break;
                PermissionRequestActivity.requestLocationPermission(context, callback);
                result.putBoolean(EXTRA_COMMAND_SUCCESS, true);
                break;
            case CMD_START:
                if (callback == null) break;
                start(callback, args != null && args.getBoolean("enableHighAccuracy"));
                result.putBoolean(EXTRA_COMMAND_SUCCESS, true);
                break;
            case CMD_STOP:
                stop();
                result.putBoolean(EXTRA_COMMAND_SUCCESS, true);
                break;
        }
        return result;
    }

    private boolean hasFine() {
        return ContextCompat.checkSelfPermission(mContext, Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
    }

    private boolean hasAny() {
        return hasFine() || ContextCompat.checkSelfPermission(mContext,
                Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean systemLocationEnabled() {
        LocationManager lm = (LocationManager) mContext.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return lm.isLocationEnabled();
        return lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
                || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
    }

    @SuppressWarnings("MissingPermission")
    private void start(@NonNull TrustedWebActivityCallbackRemote cb, boolean highAccuracy) {
        stop();
        mCallback = cb;
        if (!hasAny()) { error("Application does not have sufficient geolocation permissions."); return; }
        if (!systemLocationEnabled()) { error("Location services are turned off."); return; }
        mRunning = true;
        boolean fine = highAccuracy && hasFine();
        try {
            if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(mContext)
                    == ConnectionResult.SUCCESS) {
                mFused = LocationServices.getFusedLocationProviderClient(mContext);
                mFused.getLastLocation().addOnSuccessListener(this::send);
                LocationRequest req = new LocationRequest.Builder(
                        fine ? Priority.PRIORITY_HIGH_ACCURACY : Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                        fine ? 500 : 1000).build();
                mFused.requestLocationUpdates(req, mFusedCallback, Looper.getMainLooper())
                        .addOnFailureListener(e -> { stop(); error("Unable to request location updates: " + e); });
            } else {
                mLm = (LocationManager) mContext.getSystemService(Context.LOCATION_SERVICE);
                for (String p : new String[]{LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER}) {
                    if (p.equals(LocationManager.GPS_PROVIDER) && !fine) continue;
                    if (mLm.isProviderEnabled(p)) {
                        send(mLm.getLastKnownLocation(p));
                        mLm.requestLocationUpdates(p, 0, 0, mAndroidListener, Looper.getMainLooper());
                    }
                }
            }
        } catch (SecurityException | IllegalArgumentException | IllegalStateException e) {
            stop();
            error("Error when requesting location updates: " + e);
        }
    }

    private void stop() {
        if (!mRunning) return;
        mRunning = false;
        if (mFused != null) mFused.removeLocationUpdates(mFusedCallback);
        if (mLm != null) mLm.removeUpdates(mAndroidListener);
    }

    private void send(@Nullable Location l) {
        if (l == null || !mRunning || mCallback == null) return;
        Bundle b = new Bundle();
        b.putDouble("latitude", l.getLatitude());
        b.putDouble("longitude", l.getLongitude());
        b.putLong("timeStamp", l.getTime());
        if (l.hasAltitude()) b.putDouble("altitude", l.getAltitude());
        if (l.hasAccuracy()) b.putDouble("accuracy", l.getAccuracy());
        if (l.hasBearing()) b.putDouble("bearing", l.getBearing());
        if (l.hasSpeed()) b.putDouble("speed", l.getSpeed());
        run(CB_LOCATION, b);
    }

    private void error(String msg) {
        Bundle b = new Bundle();
        b.putString("message", msg);
        run(CB_ERROR, b);
    }

    private void run(String name, Bundle b) {
        TrustedWebActivityCallbackRemote cb = mCallback;
        if (cb == null) return;
        try { cb.runExtraCallback(name, b); } catch (RemoteException e) { stop(); }
    }
}
