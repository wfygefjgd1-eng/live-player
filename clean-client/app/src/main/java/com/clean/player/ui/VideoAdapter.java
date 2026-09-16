package com.clean.player.ui;

import android.graphics.drawable.ColorDrawable;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.recyclerview.widget.DiffUtil;
import androidx.recyclerview.widget.ListAdapter;
import androidx.recyclerview.widget.RecyclerView;

import com.bumptech.glide.Glide;
import com.clean.player.R;
import com.clean.player.model.VideoItem;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

public class VideoAdapter extends ListAdapter<VideoItem, VideoAdapter.VH> {
    public interface OnClick {
        void onClick(VideoItem item);
    }

    private static final DiffUtil.ItemCallback<VideoItem> DIFF = new DiffUtil.ItemCallback<VideoItem>() {
        @Override
        public boolean areItemsTheSame(@NonNull VideoItem a, @NonNull VideoItem b) {
            return a.idOrVideoId().equals(b.idOrVideoId());
        }

        @Override
        public boolean areContentsTheSame(@NonNull VideoItem a, @NonNull VideoItem b) {
            return Objects.equals(a.bestTitle(), b.bestTitle())
                    && Objects.equals(a.bestCover(), b.bestCover())
                    && Objects.equals(a.duration, b.duration)
                    && Objects.equals(a.play_num, b.play_num);
        }
    };

    private static final int PLACEHOLDER_COLOR = 0xFF222222;

    private final OnClick onClick;

    public VideoAdapter(OnClick onClick) {
        super(DIFF);
        this.onClick = onClick;
    }

    public void setItems(@Nullable List<VideoItem> items) {
        submitList(items == null ? null : new ArrayList<>(items));
    }

    /** 追加一页数据（分页加载用） */
    public void appendItems(@Nullable List<VideoItem> items) {
        if (items == null || items.isEmpty()) return;
        List<VideoItem> merged = new ArrayList<>(getCurrentList());
        merged.addAll(items);
        submitList(merged);
    }

    @NonNull
    @Override
    public VH onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        View v = LayoutInflater.from(parent.getContext()).inflate(R.layout.item_video, parent, false);
        return new VH(v);
    }

    @Override
    public void onBindViewHolder(@NonNull VH h, int position) {
        VideoItem item = getItem(position);
        h.tvTitle.setText(item.bestTitle());
        String meta = "";
        if (item.duration != null) meta += item.duration + "  ";
        if (item.play_num != null) meta += "播放 " + item.play_num;
        h.tvMeta.setText(meta.trim());
        String cover = item.bestCover();
        if (cover != null && !cover.isEmpty()) {
            // placeholder + dontAnimate：避免复用时封面闪烁
            Glide.with(h.ivCover)
                    .load(cover)
                    .centerCrop()
                    .placeholder(new ColorDrawable(PLACEHOLDER_COLOR))
                    .dontAnimate()
                    .into(h.ivCover);
        } else {
            h.ivCover.setImageDrawable(new ColorDrawable(PLACEHOLDER_COLOR));
        }
        h.itemView.setOnClickListener(v -> {
            if (onClick != null) onClick.onClick(item);
        });
    }

    static class VH extends RecyclerView.ViewHolder {
        ImageView ivCover;
        TextView tvTitle;
        TextView tvMeta;

        VH(@NonNull View itemView) {
            super(itemView);
            ivCover = itemView.findViewById(R.id.ivCover);
            tvTitle = itemView.findViewById(R.id.tvTitle);
            tvMeta = itemView.findViewById(R.id.tvMeta);
        }
    }
}
